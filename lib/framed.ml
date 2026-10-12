open! Core
open! Async

let max_frame_size = 256 * 1024 * 1024

let encode (writer : _ Bin_prot.Type_class.writer) v =
  Bigstring.to_string (Bin_prot.Utils.bin_dump ~header:true writer v)
;;

module Tail = struct
  type t =
    | Clean
    | Truncated of { bytes : int }
    | Corrupt of { offset : int }
  [@@deriving sexp_of, compare, equal]
end

let header_length = Bin_prot.Utils.size_header_length

module File_header = struct
  let magic = "MDFRAME1"
  let digest_length = 32
  let length = String.length magic + digest_length

  let encode ~digest =
    if String.length digest <> digest_length
    then raise_s [%message "Framed.File_header: digest must be 32 hex characters" digest];
    magic ^ digest
  ;;

  (* An old file starts with a little-endian frame size; [magic] read that way is far
     above [max_frame_size], so the two cannot be confused. *)
  let read reader =
    match%bind Reader.peek reader ~len:(String.length magic) with
    | `Eof -> return `Absent
    | `Ok prefix when not (String.equal prefix magic) -> return `Absent
    | `Ok _ ->
      let buf = Bytes.create length in
      (match%map Reader.really_read reader buf with
       | `Ok ->
         `Digest (Bytes.To_string.sub buf ~pos:(String.length magic) ~len:digest_length)
       | `Eof n -> `Truncated n)
  ;;

  let mismatch ~path ~expected ~found =
    raise_s
      [%message
        "bin_shape digest mismatch: the file was written with a different record type"
          (path : string)
          (expected : string)
          (found : string)]
  ;;
end

let read_digest path =
  Reader.with_file path ~f:(fun reader ->
    match%map File_header.read reader with
    | `Digest d -> Some d
    | `Absent | `Truncated _ -> None)
;;

let decode_header bytes =
  let buf = Bigstring.of_bytes bytes in
  Bin_prot.Utils.bin_read_size_header buf ~pos_ref:(ref 0)
;;

(* Reads frames until the end of the file, a damaged frame, or [stop ()]. Returns the tail
   and the offset just past the last complete frame. *)
let scan_frames ?(start = 0) reader ~decode ~stop ~f =
  let header = Bytes.create header_length in
  let rec loop offset =
    if stop ()
    then return (Tail.Clean, offset)
    else (
      match%bind Reader.really_read reader header with
      | `Eof 0 -> return (Tail.Clean, offset)
      | `Eof n -> return (Tail.Truncated { bytes = n }, offset)
      | `Ok ->
        let size = decode_header header in
        if size < 0 || size > max_frame_size
        then return (Tail.Corrupt { offset }, offset)
        else (
          let payload = Bytes.create size in
          match%bind Reader.really_read reader payload with
          | `Eof n -> return (Tail.Truncated { bytes = header_length + n }, offset)
          | `Ok ->
            (match decode payload ~size with
             | None -> return (Tail.Corrupt { offset }, offset)
             | Some v ->
               let%bind () = f v in
               loop (offset + header_length + size))))
  in
  loop start
;;

(* Skips the optional file header, then scans the frames. *)
let scan_file ?digest ~path reader ~decode ~stop ~f =
  match%bind File_header.read reader with
  | `Truncated n -> return (Tail.Truncated { bytes = n }, 0)
  | `Absent -> scan_frames reader ~decode ~stop ~f
  | `Digest found ->
    (match digest with
     | Some expected when not (String.equal expected found) ->
       File_header.mismatch ~path ~expected ~found
     | _ -> scan_frames ~start:File_header.length reader ~decode ~stop ~f)
;;

let decode_with (bin_reader : _ Bin_prot.Type_class.reader) payload ~size =
  let buf = Bigstring.of_bytes payload in
  let pos_ref = ref 0 in
  match bin_reader.read buf ~pos_ref with
  | v when !pos_ref = size -> Some v
  | _ -> None
  | exception _ -> None
;;

let valid_length path =
  Reader.with_file path ~f:(fun reader ->
    let%map _tail, length =
      scan_file
        ~path
        reader
        ~decode:(fun _ ~size:_ -> Some ())
        ~stop:(fun () -> false)
        ~f:(fun () -> return ())
    in
    length)
;;

let read_file ?digest bin_reader path =
  let tail = Ivar.create () in
  let pipe =
    Pipe.create_reader ~close_on_exception:true (fun w ->
      let%map t, _ =
        Reader.with_file path ~f:(fun reader ->
          scan_file
            ?digest
            ~path
            reader
            ~decode:(decode_with bin_reader)
            ~stop:(fun () -> Pipe.is_closed w)
            ~f:(fun v -> Pipe.write_if_open w v))
      in
      Ivar.fill_exn tail t)
  in
  pipe, Ivar.read tail
;;

let load_file ?digest bin_reader path =
  let pipe, tail = read_file ?digest bin_reader path in
  let%bind values = Pipe.to_list pipe in
  let%map tail in
  values, tail
;;

module Writer = struct
  module W = Async.Writer

  type 'a t =
    { bin_writer : 'a Bin_prot.Type_class.writer
    ; digest : string option
    ; path_for_date : Date.t -> string
    ; flush_bytes : int
    ; buffer : Buffer.t
    ; mutable buffer_date : Date.t option
    ; sequencer : unit Throttle.Sequencer.t
    ; mutable file : (Date.t * W.t) option
    ; mutable files : string list (** most recent first *)
    ; mutable closed : bool
    ; stop : unit Ivar.t
    }

  let close_file t =
    match t.file with
    | None -> return ()
    | Some (_, w) ->
      t.file <- None;
      W.close w
  ;;

  (* A crash can leave a partial frame at the end of a file; appending after it would hide
     every later frame from readers, so cut it off first. *)
  let repair path =
    match%bind Sys.file_exists_exn path with
    | false -> return ()
    | true ->
      let%bind valid = valid_length path in
      let%bind stat = Unix.stat path in
      if Int64.( > ) stat.size (Int64.of_int valid)
      then Unix.truncate path ~len:(Int64.of_int valid)
      else return ()
  ;;

  (* Appending to a file of another record type would make it unreadable. A file without a
     header predates headers and is continued as is. *)
  let check_header t path =
    match t.digest with
    | None -> return ()
    | Some expected ->
      (match%bind Sys.file_exists_exn path with
       | false -> return ()
       | true ->
         (match%map read_digest path with
          | Some found when not (String.equal found expected) ->
            File_header.mismatch ~path ~expected ~found
          | _ -> ()))
  ;;

  let start_file t path w =
    match t.digest with
    | None -> return ()
    | Some digest ->
      let%map stat = Unix.stat path in
      if Int64.equal stat.size 0L then W.write w (File_header.encode ~digest)
  ;;

  let file_for t date =
    match t.file with
    | Some (d, w) when Date.equal d date -> return w
    | _ ->
      let%bind () = close_file t in
      let path = t.path_for_date date in
      let%bind () = Unix.mkdir ~p:() (Filename.dirname path) in
      let%bind () = repair path in
      let%bind () = check_header t path in
      let%bind w = W.open_file ~append:true path in
      let%map () = start_file t path w in
      t.file <- Some (date, w);
      t.files <- path :: t.files;
      w
  ;;

  let write_chunk t date data =
    Throttle.enqueue t.sequencer (fun () ->
      let%bind w = file_for t date in
      W.write w data;
      W.flushed w)
  ;;

  let flush_buffer t =
    match t.buffer_date with
    | Some date when Buffer.length t.buffer > 0 ->
      let data = Buffer.contents t.buffer in
      Buffer.clear t.buffer;
      write_chunk t date data
    | _ -> Throttle.enqueue t.sequencer (fun () -> return ())
  ;;

  let create
    ?(flush_interval = Time_ns.Span.of_int_ms 100)
    ?(flush_bytes = 1024 * 1024)
    ?digest
    bin_writer
    ~path_for_date
    ()
    =
    let t =
      (match digest with
       | Some digest -> ignore (File_header.encode ~digest : string)
       | None -> ());
      { bin_writer
      ; digest
      ; path_for_date
      ; flush_bytes
      ; buffer = Buffer.create 4096
      ; buffer_date = None
      ; sequencer = Throttle.Sequencer.create ()
      ; file = None
      ; files = []
      ; closed = false
      ; stop = Ivar.create ()
      }
    in
    Clock_ns.every
      ~start:(Clock_ns.after flush_interval)
      ~stop:(Ivar.read t.stop)
      ~continue_on_error:false
      flush_interval
      (fun () -> if Buffer.length t.buffer > 0 then don't_wait_for (flush_buffer t));
    t
  ;;

  let append t v ~time =
    if t.closed then raise_s [%message "Framed.Writer.append: writer is closed"];
    let date = Store.date_of_time time in
    (match t.buffer_date with
     | Some d when Date.equal d date -> ()
     | _ ->
       if Buffer.length t.buffer > 0 then don't_wait_for (flush_buffer t);
       t.buffer_date <- Some date);
    Buffer.add_string t.buffer (encode t.bin_writer v);
    if Buffer.length t.buffer >= t.flush_bytes then don't_wait_for (flush_buffer t)
  ;;

  let flush t = flush_buffer t

  let close t =
    if t.closed
    then Throttle.enqueue t.sequencer (fun () -> return ())
    else (
      t.closed <- true;
      Ivar.fill_if_empty t.stop ();
      let%bind () = flush_buffer t in
      Throttle.enqueue t.sequencer (fun () -> close_file t))
  ;;

  let files t = List.rev t.files
end
