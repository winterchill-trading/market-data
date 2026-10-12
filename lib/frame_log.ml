open! Core

module Record = struct
  module Stable = struct
    module V1 = struct
      type t =
        { recv_ts : Time_ns.Stable.V1.t
        ; stream_id : int
        ; payload : string
        }
      [@@deriving bin_io, sexp, compare, equal, fields]
    end
  end

  include Stable.V1
end

let path ~dir instrument stream date =
  Store.path (Store.create dir) Raw instrument stream date
;;

module Writer = struct
  type t = Record.t Framed.Writer.t

  let create ?flush_interval ?flush_bytes ~dir instrument stream =
    Framed.Writer.create
      ?flush_interval
      ?flush_bytes
      Record.bin_writer_t
      ~path_for_date:(path ~dir instrument stream)
      ()
  ;;

  let append t (record : Record.t) = Framed.Writer.append t record ~time:record.recv_ts

  let write t ~recv_ts ~stream_id payload =
    append t { Record.recv_ts; stream_id; payload }
  ;;

  let flush = Framed.Writer.flush
  let close = Framed.Writer.close
  let files = Framed.Writer.files
end

let read_file path = Framed.read_file Record.bin_reader_t path
let load_file path = Framed.load_file Record.bin_reader_t path

let read_merged paths =
  Merge.sorted
    (List.map paths ~f:(fun path -> fst (read_file path)))
    ~compare:(fun (a : Record.t) (b : Record.t) -> Time_ns.compare a.recv_ts b.recv_ts)
;;
