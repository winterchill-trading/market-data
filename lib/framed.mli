(** Length-prefixed bin_io framing shared by {!Frame_log} and {!Event_log}.

    A file is a sequence of frames, each an 8-byte little-endian size header followed by
    that many bytes of bin_io payload (the layout of
    [Bin_prot.Utils.bin_dump ~header:true] and [Async.Writer.write_bin_prot]). Files are
    only ever appended to, so after a crash the only possible damage is a truncated last
    frame; readers stop there.

    A file may start with a {!File_header}: an 8-byte magic and the 32-character hex
    [bin_shape] digest of the record type. Readers given [~digest] fail on a file whose
    header names another digest; files without a header (written before headers existed)
    are read as before. *)

open! Core
open! Async

(** Frames larger than this (256 MiB) are treated as corruption. *)
val max_frame_size : int

(** One frame: size header then payload. *)
val encode : 'a Bin_prot.Type_class.writer -> 'a -> string

module File_header : sig
  (** ["MDFRAME1"]. Read as a little-endian frame size it exceeds {!max_frame_size}, so a
      headed file never looks like a headerless one. *)
  val magic : string

  (** Magic plus digest: 40 bytes. *)
  val length : int

  (** Raises unless [digest] is 32 characters long. *)
  val encode : digest:string -> string
end

(** The digest in the header of [path], or [None] for a file without one. *)
val read_digest : string -> string option Deferred.t

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
    then.

    With [digest], raises if the file's header carries a different digest. *)
val read_file
  :  ?digest:string
  -> 'a Bin_prot.Type_class.reader
  -> string
  -> 'a Pipe.Reader.t * Tail.t Deferred.t

(** Length in bytes of the header and the complete frames at the start of [path]. *)
val valid_length : string -> int Deferred.t

(** All complete frames of [path], and its tail. *)
val load_file
  :  ?digest:string
  -> 'a Bin_prot.Type_class.reader
  -> string
  -> ('a list * Tail.t) Deferred.t

(** Buffered append-only writer with daily files.

    Each value is appended with a timestamp; its UTC date picks the file
    ([path_for_date]), so a new file starts with the first value of each day. Missing
    directories are created. Encoded frames are buffered and written out every
    [flush_interval] (default 100ms), when the buffer reaches [flush_bytes] (default 1
    MiB), on {!flush}, and on {!close}. Files are opened in append mode, so restarting a
    writer on the same day continues the existing file, after cutting off any damaged tail
    a crash left behind.

    With [digest], every new file starts with a {!File_header}, and appending to an
    existing file whose header names another digest raises. *)
module Writer : sig
  type 'a t

  val create
    :  ?flush_interval:Time_ns.Span.t
    -> ?flush_bytes:int
    -> ?digest:string
    -> 'a Bin_prot.Type_class.writer
    -> path_for_date:(Date.t -> string)
    -> unit
    -> 'a t

  (** Raises if [t] is closed. *)
  val append : 'a t -> 'a -> time:Time_ns.t -> unit

  (** Becomes determined once everything appended so far is handed to the OS. *)
  val flush : _ t -> unit Deferred.t

  (** Flushes and closes the current file. Idempotent. *)
  val close : _ t -> unit Deferred.t

  (** Files opened so far, in order. *)
  val files : _ t -> string list
end
