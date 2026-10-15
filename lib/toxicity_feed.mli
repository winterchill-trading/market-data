(** {!Toxicity} over a live or replayed {!Feed.t}: one state per instrument, created on
    the instrument's first trade, and a pipe of the toxicity events of every instrument in
    the order their buckets fill. *)

open! Core
open! Async

(** Reads [trades] to the end. [config] picks the parameters of each instrument; [None]
    ignores its trades. Events are written with pushback, so a slow reader slows the trade
    consumption. When [trades] closes, every state is flushed (the bulk classification's
    bar in progress, in instrument order) and the result closes. Closing the result early
    stops reading. *)
val of_trades
  :  config:(Instrument.t -> Toxicity.Config.t option)
  -> Trade.t Pipe.Reader.t
  -> Toxicity.Event.t Pipe.Reader.t

(** [of_trades] over the feed's [trades] pipe. Reads only that pipe; the caller still owns
    the feed and its other pipes. *)
val of_feed
  :  config:(Instrument.t -> Toxicity.Config.t option)
  -> Feed.t
  -> Toxicity.Event.t Pipe.Reader.t
