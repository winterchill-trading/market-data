open! Core
module Md_stream = Stream

module Reason = struct
  type t =
    | Disconnect
    | Resync
  [@@deriving sexp, compare, equal]
end

type t =
  { recv_ts : Time_ns.Alternate_sexp.t
  ; venue : Venue.t
  ; instrument : Instrument.t option
  ; stream : Md_stream.t option
  ; reason : Reason.t
  }
[@@deriving sexp_of, compare, equal]
