(** Rebuilds the normalized event logs of a day from market-recorder raw minute files
    ({!Raw_minute}), with venue normalizers supplied by the feed libraries
    ({!Normalizer.S}).

    Each raw [(venue, stream, symbol)] series gets a fresh normalizer, fed its minute
    files in order through {!Raw_reader}; a gap (empty line) calls [disconnect]. Events
    are appended to an {!Event_log.Writer} under [out_dir]. Series of venues without a
    normalizer are counted and skipped. A series whose normalizer emits events of another
    stream that a second series also emits would interleave out of [recv_ts] order in that
    file; recorder series map one to one onto streams, so this does not happen with the
    venues so far. *)

open! Core
open! Async

module Stats : sig
  type t =
    { files : int (** minute files read *)
    ; frames : int
    ; disconnects : int
    ; events : int (** events written *)
    ; frame_errors : int
    (** frames the normalizer rejected, plus raw lines that do not parse and minute files
        that cannot be read *)
    ; first_errors : Error.t list
    (** up to 10, tagged with the file relative to [data_dir] *)
    ; skipped_files : int (** minute files of venues without a normalizer *)
    ; skipped_venues : Venue.t list
    }
  [@@deriving sexp_of]
end

(** One minute, the recorder's default. *)
val default_snapshot_interval : Time_ns.Span.t

(** Fails without writing when [out_dir] exists and is not empty: event logs are appended
    to, so rebuilding over existing files would duplicate events.

    L2 events also feed the {!Snapshot_index} files under [norm/l2/_snapshots/], written
    by the same {!Event_log.Writer} the recorder uses, so a rebuilt day has the same index
    as a recorded one. [snapshot_interval] defaults to {!default_snapshot_interval}; zero
    or less writes no index. *)
val run
  :  ?snapshot_interval:Time_ns.Span.t
  -> normalizers:Normalizer.t list
  -> data_dir:string
  -> out_dir:string
  -> Date.t
  -> Stats.t Or_error.t Deferred.t

(** A [rebuild-norm] command over [normalizers], for binaries that link feed libraries. *)
val command : Normalizer.t list -> Command.t
