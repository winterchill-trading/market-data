(** A {!Feed.t} replaying recorded events in [recv_ts] order.

    With [speed > 0] events are paced on [time_source] (default the wall clock, as
    [Clock_ns]): an event [d] after the first one is delivered [d / speed] after the
    replay starts, so [speed = 1.] is real time and [speed = 10.] ten times faster. With
    [speed = 0.] events are delivered as fast as the consumers read them.

    Delivery honours pushback on every pipe, so a pipe nobody reads stalls the replay;
    [Pipe.close_read] the ones you do not need. All pipes close at the end of the input. *)

open! Core
module Md_stream := Stream
open! Async

(** Replays [events], which must be sorted by [recv_ts]. *)
val of_events
  :  ?speed:float
  -> ?time_source:Time_source.t
  -> Event.t Pipe.Reader.t
  -> Feed.t

(** Replays [items], sorted by [recv_ts]; gaps go to [gaps] without pushback. *)
val of_items
  :  ?speed:float
  -> ?time_source:Time_source.t
  -> [ `Event of Event.t | `Gap of Gap.t ] Pipe.Reader.t
  -> Feed.With_gaps.t

(** Replays the recorder's raw minute files of [symbol] on [normalizer]'s venue with
    [recv_ts] in the half-open interval from [start] (inclusive) to [stop] (exclusive)
    ({!Raw_reader.read}), turning frames into events with [normalizer] (one state per
    stream). Each empty raw line resets that stream's normalizer and is reported as a
    {!Gap.Reason.Disconnect} gap for the stream. Frames the normalizer rejects and
    unreadable lines go to [on_error] (default: logged) and are skipped. *)
val of_raw
  :  ?speed:float
  -> ?time_source:Time_source.t
  -> ?streams:Md_stream.t list
  -> ?on_error:(Error.t -> unit)
  -> normalizer:Normalizer.t
  -> data_dir:string
  -> symbol:string
  -> start:Time_ns.t
  -> stop:Time_ns.t
  -> unit
  -> Feed.With_gaps.t

(** Replays {!Event_log} files, merged by [recv_ts]. *)
val of_files : ?speed:float -> ?time_source:Time_source.t -> string list -> Feed.t

(** Like {!of_files}, also reporting each file that ends in a truncated or corrupt frame
    as a {!Gap.Reason.Damaged_log} gap at the file's last event. *)
val of_files_with_gaps
  :  ?speed:float
  -> ?time_source:Time_source.t
  -> string list
  -> Feed.With_gaps.t

(** Replays the {!Event_log} files of [streams] (default trades, bbo, l2 and funding) of
    [instruments] for the UTC days [[from, to_]] under [dir]. Fails, naming the range,
    when no such file exists, rather than returning a feed that ends at once.

    With [start_at], each instrument starts at its last {!Snapshot_index} entry at or
    before [start_at] (same day): that book is delivered first as an L2 [Snapshot], then
    the instrument's events from the entry's time on. An instrument without such an entry
    (or when [streams] has no [L2]) starts at [start_at] with no snapshot, so its book
    stays incomplete until the venue's next snapshot. Days before [start_at]'s are not
    read. *)
val of_range
  :  ?speed:float
  -> ?time_source:Time_source.t
  -> ?streams:Md_stream.t list
  -> ?start_at:Time_ns.t
  -> dir:string
  -> Instrument.t list
  -> from:Date.t
  -> to_:Date.t
  -> Feed.t Or_error.t Deferred.t
