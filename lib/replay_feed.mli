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

(** Replays {!Event_log} files, merged by [recv_ts]. *)
val of_files : ?speed:float -> ?time_source:Time_source.t -> string list -> Feed.t

(** Replays the {!Event_log} files of [streams] (default trades, bbo, l2 and funding) of
    [instruments] for the UTC days [[from, to_]] under [dir]. Fails, naming the range,
    when no such file exists, rather than returning a feed that ends at once. *)
val of_range
  :  ?speed:float
  -> ?time_source:Time_source.t
  -> ?streams:Md_stream.t list
  -> dir:string
  -> Instrument.t list
  -> from:Date.t
  -> to_:Date.t
  -> Feed.t Or_error.t Deferred.t
