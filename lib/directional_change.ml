open! Core
module Float_u = Stdlib_upstream_compatible.Float_u

module Direction = struct
  type t =
    | Up
    | Down
  [@@deriving sexp, compare, equal, enumerate]
end

module Event = struct
  type t =
    { direction : Direction.t
    ; extreme_ts : Time_ns.t
    ; extreme_price : Price.t
    ; confirm_ts : Time_ns.t
    ; confirm_price : Price.t
    ; overshoot : float option
    }
  [@@deriving sexp, compare, equal]
end

(* [trend] is 0 before the first event, then 1 (up) or -1 (down). Before the first event
   [high] and [low] are the extremes since the first price; afterwards only [extreme] (the
   high of an up trend, the low of a down trend) is used. *)
type t =
  { mutable trend : int
  ; mutable started : bool
  ; mutable high : Price.t
  ; mutable high_ts : Time_ns.t
  ; mutable low : Price.t
  ; mutable low_ts : Time_ns.t
  ; mutable extreme : Price.t
  ; mutable extreme_ts : Time_ns.t
  ; mutable confirm : Price.t
  ; up_factor : Float_u.t
  ; down_factor : Float_u.t
  }

let create ~theta =
  if not (Float.( > ) theta 0. && Float.( < ) theta 1.)
  then
    raise_s
      [%message "Directional_change.create: theta must be in (0, 1)" (theta : float)];
  { trend = 0
  ; started = false
  ; high = Price.zero
  ; high_ts = Time_ns.epoch
  ; low = Price.zero
  ; low_ts = Time_ns.epoch
  ; extreme = Price.zero
  ; extreme_ts = Time_ns.epoch
  ; confirm = Price.zero
  ; up_factor = Float_u.of_float (1. +. theta)
  ; down_factor = Float_u.of_float (1. -. theta)
  }
;;

let theta t = Float_u.to_float (Float_u.sub t.up_factor #1.)
let units p = Float_u.of_int (Price.to_units p)

(* [price >= base * (1 + theta)] *)
let rose_from t ~base price =
  Float_u.compare (units price) (Float_u.mul (units base) t.up_factor) >= 0
;;

(* [price <= base * (1 - theta)] *)
let fell_from t ~base price =
  Float_u.compare (units price) (Float_u.mul (units base) t.down_factor) <= 0
;;

let trend t =
  match t.trend with
  | 1 -> Some Direction.Up
  | -1 -> Some Down
  | _ -> None
;;

let overshoot ~confirm ~extreme =
  Float.abs (Price.to_float extreme -. Price.to_float confirm) /. Price.to_float confirm
;;

(* Confirms a new trend at [price]: the event, and the state of the new trend. *)
let confirm t ~(direction : Direction.t) ~extreme ~extreme_ts ~overshoot ~time price =
  let event =
    { Event.direction
    ; extreme_ts
    ; extreme_price = extreme
    ; confirm_ts = time
    ; confirm_price = price
    ; overshoot
    }
  in
  t.trend
  <- (match direction with
      | Up -> 1
      | Down -> -1);
  t.extreme <- price;
  t.extreme_ts <- time;
  t.confirm <- price;
  This event
;;

let add t ~time price =
  match t.trend with
  | 0 ->
    if not t.started
    then (
      t.started <- true;
      t.high <- price;
      t.high_ts <- time;
      t.low <- price;
      t.low_ts <- time;
      Null)
    else if rose_from t ~base:t.low price
    then
      confirm
        t
        ~direction:Up
        ~extreme:t.low
        ~extreme_ts:t.low_ts
        ~overshoot:None
        ~time
        price
    else if fell_from t ~base:t.high price
    then
      confirm
        t
        ~direction:Down
        ~extreme:t.high
        ~extreme_ts:t.high_ts
        ~overshoot:None
        ~time
        price
    else (
      if Price.( > ) price t.high
      then (
        t.high <- price;
        t.high_ts <- time);
      if Price.( < ) price t.low
      then (
        t.low <- price;
        t.low_ts <- time);
      Null)
  | 1 ->
    if Price.( > ) price t.extreme
    then (
      t.extreme <- price;
      t.extreme_ts <- time;
      Null)
    else if fell_from t ~base:t.extreme price
    then
      confirm
        t
        ~direction:Down
        ~extreme:t.extreme
        ~extreme_ts:t.extreme_ts
        ~overshoot:(Some (overshoot ~confirm:t.confirm ~extreme:t.extreme))
        ~time
        price
    else Null
  | _ ->
    if Price.( < ) price t.extreme
    then (
      t.extreme <- price;
      t.extreme_ts <- time;
      Null)
    else if rose_from t ~base:t.extreme price
    then
      confirm
        t
        ~direction:Up
        ~extreme:t.extreme
        ~extreme_ts:t.extreme_ts
        ~overshoot:(Some (overshoot ~confirm:t.confirm ~extreme:t.extreme))
        ~time
        price
    else Null
;;

let add_trade t (trade : Trade.t) = add t ~time:trade.exch_ts trade.price

let of_prices ~theta prices =
  let t = create ~theta in
  List.filter_map prices ~f:(fun (time, price) ->
    match add t ~time price with
    | This e -> Some e
    | Null -> None)
;;
