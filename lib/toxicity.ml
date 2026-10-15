open! Core
module Float_u = Stdlib_upstream_compatible.Float_u

module Classification = struct
  type t =
    | Aggressor
    | Tick_rule
    | Bulk of
        { interval : Time_ns.Span.t
        ; span : int
        }
  [@@deriving sexp, compare, equal]

  let to_string = function
    | Aggressor -> "aggressor"
    | Tick_rule -> "tick-rule"
    | Bulk { interval; span = _ } -> "bulk-" ^ Time_ns.Span.to_string interval
  ;;

  let of_string s =
    match s with
    | "aggressor" -> Ok Aggressor
    | "tick-rule" -> Ok Tick_rule
    | _ ->
      (match String.chop_prefix s ~prefix:"bulk-" with
       | Some interval ->
         Or_error.try_with (fun () ->
           Bulk { interval = Time_ns.Span.of_string interval; span = 20 })
       | None -> Or_error.error_s [%message "Toxicity: unknown classification" s])
  ;;
end

module Config = struct
  type t =
    { bucket_volume : Size.t
    ; window : int
    ; zscore_window : int
    ; classification : Classification.t
    }
  [@@deriving sexp, compare, equal]

  let default ~bucket_volume =
    { bucket_volume; window = 50; zscore_window = 250; classification = Aggressor }
  ;;

  let validate t =
    let bulk_ok =
      match t.classification with
      | Aggressor | Tick_rule -> true
      | Bulk { interval; span } -> Time_ns.Span.is_positive interval && span >= 1
    in
    if Size.is_positive t.bucket_volume
       && t.window >= 1
       && t.zscore_window >= 1
       && bulk_ok
    then Ok t
    else Or_error.error_s [%message "Toxicity: invalid config" ~_:(t : t)]
  ;;
end

module Event = struct
  type t =
    { instrument : Instrument.t
    ; bucket : int
    ; start_ts : Time_ns.t
    ; end_ts : Time_ns.t
    ; buy_volume : float
    ; sell_volume : float
    ; imbalance : float
    ; dominant : Side.t option
    ; vpin : float
    ; buckets : int
    ; zscore : float option
    ; cdf : float option
    }
  [@@deriving sexp, compare, equal]
end

(* Rings of the last order imbalances and of the previous VPIN values; the unboxed
   accumulators come last and are written in place. *)
type t =
  { instrument : Instrument.t
  ; config : Config.t
  ; imbalances : float array
  ; mutable imbalance_count : int
  ; mutable imbalance_pos : int
  ; history : float array
  ; mutable history_count : int
  ; mutable history_pos : int
  ; mutable bucket : int
  ; mutable start_ts : Time_ns.t
  ; mutable last_vpin : float
  ; mutable has_last_price : bool
  ; mutable last_price : Price.t
  ; mutable bar : int (** Bulk: index of the bar in progress, -1 before any *)
  ; mutable bar_volume : Size.t
  ; mutable bar_price : Price.t
  ; mutable bar_ts : Time_ns.t
  ; mutable has_prev_bar : bool
  ; mutable prev_bar_price : Price.t
  ; mutable has_var : bool
  ; capacity : Float_u.t
  ; mutable buy : Float_u.t
  ; mutable sell : Float_u.t
  ; mutable last_share : Float_u.t (** Tick_rule: buy share of the previous trade *)
  ; mutable dp_var : Float_u.t (** Bulk: EWMA of dP^2 *)
  }

let of_units u = Float_u.mul (Float_u.of_int u) #0.00000001

let create instrument config =
  let config = Config.validate config |> ok_exn in
  { instrument
  ; config
  ; imbalances = Array.create ~len:config.window 0.
  ; imbalance_count = 0
  ; imbalance_pos = 0
  ; history = Array.create ~len:config.zscore_window 0.
  ; history_count = 0
  ; history_pos = 0
  ; bucket = 0
  ; start_ts = Time_ns.epoch
  ; last_vpin = Float.nan
  ; has_last_price = false
  ; last_price = Price.zero
  ; bar = -1
  ; bar_volume = Size.zero
  ; bar_price = Price.zero
  ; bar_ts = Time_ns.epoch
  ; has_prev_bar = false
  ; prev_bar_price = Price.zero
  ; has_var = false
  ; capacity = of_units (Size.to_units config.bucket_volume)
  ; buy = #0.
  ; sell = #0.
  ; last_share = #0.5
  ; dp_var = #0.
  }
;;

let instrument t = t.instrument
let config t = t.config
let vpin t = t.last_vpin
let pending_volume t = Float_u.to_float (Float_u.add t.buy t.sell)

(* Mean and standard deviation of the previous VPIN values, and the share at or below
   [vpin]. *)
let zscore_and_cdf t ~vpin =
  let n = t.history_count in
  if n = 0
  then None, None
  else (
    let sum = ref 0. in
    (* Mid-rank: values equal to [vpin] count half, so a flat history gives 0.5. *)
    let below = ref 0. in
    for i = 0 to n - 1 do
      let v = t.history.(i) in
      sum := !sum +. v;
      if Float.( < ) v vpin
      then below := !below +. 1.
      else if Float.( = ) v vpin
      then below := !below +. 0.5
    done;
    let mean = !sum /. Float.of_int n in
    let ss = ref 0. in
    for i = 0 to n - 1 do
      let d = t.history.(i) -. mean in
      ss := !ss +. (d *. d)
    done;
    let cdf = Some (!below /. Float.of_int n) in
    if n < 2
    then None, cdf
    else (
      let sd = Float.sqrt (!ss /. Float.of_int (n - 1)) in
      (* VPIN lies in [0, 1]; a deviation below 1e-9 is rounding in the mean of equal
         values, and dividing by it gives z-scores of 10^15. *)
      if Float.( > ) sd 1e-9 then Some ((vpin -. mean) /. sd), cdf else None, cdf))
;;

let complete t ~ts : Event.t =
  let buy = Float_u.to_float t.buy in
  let sell = Float_u.to_float t.sell in
  let volume = buy +. sell in
  let imbalance = (buy -. sell) /. volume in
  let window = t.config.window in
  t.imbalances.(t.imbalance_pos) <- Float.abs imbalance;
  t.imbalance_pos <- (t.imbalance_pos + 1) % window;
  t.imbalance_count <- Int.min window (t.imbalance_count + 1);
  let total = ref 0. in
  for i = 0 to t.imbalance_count - 1 do
    total := !total +. t.imbalances.(i)
  done;
  let vpin = !total /. Float.of_int t.imbalance_count in
  let zscore, cdf = zscore_and_cdf t ~vpin in
  let zw = t.config.zscore_window in
  t.history.(t.history_pos) <- vpin;
  t.history_pos <- (t.history_pos + 1) % zw;
  t.history_count <- Int.min zw (t.history_count + 1);
  let event =
    { Event.instrument = t.instrument
    ; bucket = t.bucket
    ; start_ts = t.start_ts
    ; end_ts = ts
    ; buy_volume = buy
    ; sell_volume = sell
    ; imbalance
    ; dominant =
        (if Float.( > ) buy sell
         then Some Side.Buy
         else if Float.( < ) buy sell
         then Some Sell
         else None)
    ; vpin
    ; buckets = t.imbalance_count
    ; zscore
    ; cdf
    }
  in
  t.last_vpin <- vpin;
  t.bucket <- t.bucket + 1;
  t.buy <- #0.;
  t.sell <- #0.;
  event
;;

(* Pours [volume] split at [share] into the buckets, oldest event last in [acc]. *)
let rec pour t ~share ~volume ~ts acc =
  if Float_u.compare (Float_u.add t.buy t.sell) #0. = 0 then t.start_ts <- ts;
  let room = Float_u.sub t.capacity (Float_u.add t.buy t.sell) in
  if Float_u.compare volume room < 0
  then (
    t.buy <- Float_u.add t.buy (Float_u.mul share volume);
    t.sell <- Float_u.add t.sell (Float_u.mul (Float_u.sub #1. share) volume);
    acc)
  else (
    t.buy <- Float_u.add t.buy (Float_u.mul share room);
    t.sell <- Float_u.add t.sell (Float_u.mul (Float_u.sub #1. share) room);
    let event = complete t ~ts in
    let rest = Float_u.sub volume room in
    if Float_u.compare rest #0. > 0
    then pour t ~share ~volume:rest ~ts (event :: acc)
    else event :: acc)
;;

let finish = function
  | ([] | [ _ ]) as l -> l
  | l -> List.rev l
;;

let normal_cdf x =
  Float_u.mul #0.5 (Float_u.add #1. (Float_u.erf (Float_u.div x #1.4142135623730951)))
;;

(* Classifies the bar in progress and pours it. *)
let close_bar t ~span =
  let price = t.bar_price in
  let share =
    if not t.has_prev_bar
    then #0.5
    else (
      let dp = of_units (Price.to_units price - Price.to_units t.prev_bar_price) in
      let share =
        if t.has_var && Float_u.compare t.dp_var #0. > 0
        then normal_cdf (Float_u.div dp (Float_u.sqrt t.dp_var))
        else #0.5
      in
      let alpha = Float_u.div #2. (Float_u.of_int (span + 1)) in
      let sq = Float_u.mul dp dp in
      t.dp_var
      <- (if t.has_var
          then Float_u.add t.dp_var (Float_u.mul alpha (Float_u.sub sq t.dp_var))
          else sq);
      t.has_var <- true;
      share)
  in
  t.has_prev_bar <- true;
  t.prev_bar_price <- price;
  let volume = of_units (Size.to_units t.bar_volume) in
  t.bar_volume <- Size.zero;
  finish (pour t ~share ~volume ~ts:t.bar_ts [])
;;

let add t (trade : Trade.t) =
  match t.config.classification with
  | Aggressor ->
    let share =
      match trade.side with
      | Buy -> #1.
      | Sell -> #0.
    in
    finish
      (pour t ~share ~volume:(of_units (Size.to_units trade.size)) ~ts:trade.exch_ts [])
  | Tick_rule ->
    let share =
      if not t.has_last_price
      then #0.5
      else if Price.( > ) trade.price t.last_price
      then #1.
      else if Price.( < ) trade.price t.last_price
      then #0.
      else t.last_share
    in
    t.has_last_price <- true;
    t.last_price <- trade.price;
    t.last_share <- share;
    finish
      (pour t ~share ~volume:(of_units (Size.to_units trade.size)) ~ts:trade.exch_ts [])
  | Bulk { interval; span } ->
    let bar =
      Time_ns.to_int_ns_since_epoch trade.exch_ts / Time_ns.Span.to_int_ns interval
    in
    let events = if t.bar >= 0 && bar <> t.bar then close_bar t ~span else [] in
    t.bar <- bar;
    t.bar_volume <- Size.( + ) t.bar_volume trade.size;
    t.bar_price <- trade.price;
    t.bar_ts <- trade.exch_ts;
    events
;;

let flush t =
  match t.config.classification with
  | Bulk { span; interval = _ } when t.bar >= 0 && Size.is_positive t.bar_volume ->
    close_bar t ~span
  | _ -> []
;;

let of_trades instrument config trades =
  let t = create instrument config in
  let events = List.concat_map trades ~f:(add t) in
  events @ flush t
;;
