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

let decode_header bytes =
  let buf = Bigstring.of_bytes bytes in
  Bin_prot.Utils.bin_read_size_header buf ~pos_ref:(ref 0)
;;

let read_frames (bin_reader : _ Bin_prot.Type_class.reader) reader ~stop ~f =
  let header = Bytes.create header_length in
  let rec loop offset =
    if stop ()
    then return Tail.Clean
    else (
      match%bind Reader.really_read reader header with
      | `Eof 0 -> return Tail.Clean
      | `Eof n -> return (Tail.Truncated { bytes = n })
      | `Ok ->
        let size = decode_header header in
        if size < 0 || size > max_frame_size
        then return (Tail.Corrupt { offset })
        else (
          let payload = Bytes.create size in
          match%bind Reader.really_read reader payload with
          | `Eof n -> return (Tail.Truncated { bytes = header_length + n })
          | `Ok ->
            let buf = Bigstring.of_bytes payload in
            let pos_ref = ref 0 in
            (match bin_reader.read buf ~pos_ref with
             | v when !pos_ref = size ->
               let%bind () = f v in
               loop (offset + header_length + size)
             | _ -> return (Tail.Corrupt { offset })
             | exception _ -> return (Tail.Corrupt { offset }))))
  in
  loop 0
;;

let read_file bin_reader path =
  let tail = Ivar.create () in
  let pipe =
    Pipe.create_reader ~close_on_exception:true (fun w ->
      let%map t =
        Reader.with_file path ~f:(fun reader ->
          read_frames
            bin_reader
            reader
            ~stop:(fun () -> Pipe.is_closed w)
            ~f:(fun v -> Pipe.write_if_open w v))
      in
      Ivar.fill_exn tail t)
  in
  pipe, Ivar.read tail
;;

let load_file bin_reader path =
  let pipe, tail = read_file bin_reader path in
  let%bind values = Pipe.to_list pipe in
  let%map tail in
  values, tail
;;
