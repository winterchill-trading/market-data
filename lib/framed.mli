(** Length-prefixed bin_io framing shared by {!Frame_log} and {!Event_log}.

    A file is a sequence of frames, each an 8-byte little-endian size header followed by
    that many bytes of bin_io payload (the layout of
    [Bin_prot.Utils.bin_dump ~header:true] and [Async.Writer.write_bin_prot]). Files are
    only ever appended to, so after a crash the only possible damage is a truncated last
    frame; readers stop there. *)

open! Core
open! Async

(** Frames larger than this (256 MiB) are treated as corruption. *)
val max_frame_size : int

(** One frame: size header then payload. *)
val encode : 'a Bin_prot.Type_class.writer -> 'a -> string

(** What followed the last complete frame of a file. *)
module Tail : sig
  type t =
    | Clean
    | Truncated of { bytes : int } (** a partial frame of this many bytes was dropped *)
    | Corrupt of { offset : int } (** an impossible size header at this offset *)
  [@@deriving sexp_of, compare, equal]
end

(** [read_file reader path] streams the complete frames of [path] in file order. The pipe
    closes at the end of the file or at the first damaged frame; [tail] is determined
    then. *)
val read_file
  :  'a Bin_prot.Type_class.reader
  -> string
  -> 'a Pipe.Reader.t * Tail.t Deferred.t

(** All complete frames of [path], and its tail. *)
val load_file : 'a Bin_prot.Type_class.reader -> string -> ('a list * Tail.t) Deferred.t
