open! Core
module Md_stream = Stream
open! Async

let time t = Time_ns.to_string_iso8601_basic t ~zone:Time_float.Zone.utc

let level (l : L2_update.Level.t) =
  sprintf "%s x %s" (Price.to_string l.price) (Size.to_string l.size)
;;

let levels l = "[" ^ String.concat ~sep:", " (List.map l ~f:level) ^ "]"

let payload : Event.t -> string = function
  | Trade t ->
    sprintf
      "%s %s @ %s id=%s"
      (match t.side with
       | Buy -> "buy"
       | Sell -> "sell")
      (Size.to_string t.size)
      (Price.to_string t.price)
      t.trade_id
  | Bbo b ->
    sprintf
      "%s x %s / %s x %s"
      (Price.to_string b.bid_price)
      (Size.to_string b.bid_size)
      (Price.to_string b.ask_price)
      (Size.to_string b.ask_size)
  | L2 u ->
    sprintf
      "%s bids=%s asks=%s"
      (match u.kind with
       | Snapshot -> "snapshot"
       | Delta -> "delta")
      (levels u.bids)
      (levels u.asks)
  | Funding f ->
    sprintf
      "rate=%s mark=%s index=%s next=%s"
      (Float.to_string f.rate)
      (Price.to_string f.mark_price)
      (Price.to_string f.index_price)
      (time f.next_funding_time)
;;

let line event =
  sprintf
    "%s %s %s %s"
    (time (Event.recv_ts event))
    (Instrument.to_string (Event.instrument event))
    (Md_stream.to_string (Event.stream event))
    (payload event)
;;

let print files =
  Pipe.iter_without_pushback (Event_log.read_merged files) ~f:(fun e ->
    print_endline (line e))
;;

let book_at files ~at =
  let events = Event_log.read_merged files in
  let books = ref Instrument.Map.empty in
  let%map () =
    Pipe.iter_without_pushback events ~f:(fun (e : Event.t) ->
      if Time_ns.( > ) (Event.recv_ts e) at
      then Pipe.close_read events
      else (
        match e with
        | L2 u ->
          books
          := Map.update !books u.instrument ~f:(fun b ->
               L2_book.apply (Option.value b ~default:L2_book.empty) u)
        | Trade _ | Bbo _ | Funding _ -> ()))
  in
  Map.to_alist !books
;;
