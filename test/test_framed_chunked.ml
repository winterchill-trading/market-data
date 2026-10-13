open! Core
open! Async
open Market_data
module E = Event.Stable.V1

type damage =
  | Intact
  | Truncate of int (** keep this many permille of the file *)
  | Huge_size of int (** frame index whose size header becomes impossible *)
  | Overwrite of int * char (** byte at this permille of the file *)
[@@deriving sexp_of, quickcheck]

let damage_gen =
  let open Quickcheck.Generator in
  let permille = Int.gen_incl 0 1_000 in
  union
    [ return Intact
    ; map permille ~f:(fun p -> Truncate p)
    ; map (Int.gen_incl 0 30) ~f:(fun k -> Huge_size k)
    ; map (both permille Char.quickcheck_generator) ~f:(fun (p, c) -> Overwrite (p, c))
    ]
;;

let file_bytes ~header events damage =
  let frames = List.map events ~f:(Framed.encode E.bin_writer_t) in
  let prefix =
    if header then Framed.File_header.encode ~digest:Event_log.digest else ""
  in
  let bytes = Bytes.of_string (String.concat (prefix :: frames)) in
  let n = Bytes.length bytes in
  let at p = Int.min (n - 1) (n * p / 1_000) in
  match damage with
  | Intact -> Bytes.to_string bytes
  | Truncate p -> Bytes.To_string.sub bytes ~pos:0 ~len:(n * p / 1_000)
  | Overwrite (_, _) when n = 0 -> ""
  | Overwrite (p, c) ->
    Bytes.set bytes (at p) c;
    Bytes.to_string bytes
  | Huge_size k ->
    (match List.nth frames k with
     | None -> ()
     | Some _ ->
       let pos =
         String.length prefix
         + List.sum (module Int) (List.take frames k) ~f:String.length
       in
       Bytes.set bytes (pos + 6) '\x7f');
    Bytes.to_string bytes
;;

(* Events as their bin_io bytes: a NaN funding rate is not [equal] to itself. *)
type outcome =
  | Read of string list * Framed.Tail.t
  | Raised_size_overflow of string list
  (** the per-frame reader raised [Int_overflow] on a size header with its top bit set,
      after these events; the chunked reader reports [Corrupt] there instead *)
  | Raised (** damage inside the file header changed its digest *)
[@@deriving sexp_of, equal]

let read reader ~buf_len path =
  let events = Queue.create () in
  let events_list () =
    Queue.to_list events |> List.map ~f:(Binable.to_string (module E))
  in
  match%map
    Monitor.try_with (fun () ->
      let pipe, tail = reader ~buf_len path in
      let%bind () = Pipe.iter_without_pushback pipe ~f:(Queue.enqueue events) in
      tail)
  with
  | Ok tail -> Read (events_list (), tail)
  | Error exn ->
    (match Monitor.extract_exn exn with
     | Bin_prot.Common.Read_error (Int_overflow, _) ->
       Raised_size_overflow (events_list ())
     | _ -> Raised)
;;

let agree ~chunked ~per_frame =
  match per_frame, chunked with
  | Raised_size_overflow events, Read (events', Corrupt _) ->
    [%equal: string list] events events'
  | _ -> [%equal: outcome] chunked per_frame
;;

let%test_unit "chunked and per-frame readers agree on damaged files" =
  Quickcheck.test
    ~trials:300
    Quickcheck.Generator.(
      tuple4
        (List.gen_with_length 20 E.quickcheck_generator)
        damage_gen
        (Int.gen_log_uniform_incl 1 4_096)
        Bool.quickcheck_generator)
    ~sexp_of:[%sexp_of: E.t list * damage * int * bool]
    ~f:(fun (events, damage, buf_len, header) ->
      let chunked, per_frame =
        Thread_safe.block_on_async_exn (fun () ->
          Sample.with_temp_dir (fun dir ->
            let path = dir ^/ "events.bin" in
            Out_channel.write_all path ~data:(file_bytes ~header events damage);
            let%bind chunked =
              read
                (fun ~buf_len path ->
                  Framed.read_file ~digest:Event_log.digest ~buf_len E.bin_reader_t path)
                ~buf_len
                path
            in
            let%map per_frame =
              read
                (fun ~buf_len path ->
                  Framed.For_testing.read_file_per_frame
                    ~digest:Event_log.digest
                    ~buf_len
                    E.bin_reader_t
                    path)
                ~buf_len
                path
            in
            chunked, per_frame))
      in
      if not (agree ~chunked ~per_frame)
      then raise_s [%message "readers disagree" (chunked : outcome) (per_frame : outcome)])
;;
