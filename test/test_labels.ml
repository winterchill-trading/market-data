open! Core
open Market_data

let series prices =
  let prices = Array.of_list prices in
  Array.init (Array.length prices) ~f:(fun i -> Sample.ts (i * 1000)), prices
;;

let print labels =
  List.iter labels ~f:(fun (l : Labels.Label.t) ->
    printf
      "entry %d -> exit %d %-11s return %+.4f label %d\n"
      l.index
      l.exit_index
      (Sexp.to_string [%sexp (l.barrier : Labels.Barrier.t)])
      l.return
      l.label)
;;

let barriers : Labels.Barriers.t =
  { profit_take = Some 2.
  ; stop_loss = Some 1.
  ; vertical = Some (Time_ns.Span.of_int_sec 4)
  }
;;

let event ?side index : Labels.Event.t = { index; width = 0.01; side }

let%expect_test "each barrier, at width 1%: profit at +2%, stop at -1%, 4s horizon" =
  let times, prices =
    series [ 100.; 100.5; 101.; 102.5; 101.; 99.5; 98.9; 99.; 99.2; 99.4; 99.3 ]
  in
  print
    (Labels.label
       ~times
       ~prices
       barriers
       [ event 0; event 3; event 6; event 10; event 6 ~side:Sell; event 0 ~side:Sell ]);
  [%expect
    {|
    entry 0 -> exit 3 Profit_take return +0.0250 label 1
    entry 3 -> exit 4 Stop_loss   return -0.0146 label -1
    entry 6 -> exit 10 End_of_data return +0.0040 label 1
    entry 10 -> exit 10 End_of_data return +0.0000 label 0
    entry 6 -> exit 10 End_of_data return -0.0040 label 0
    entry 0 -> exit 2 Stop_loss   return -0.0100 label 0
    |}]
;;

let%expect_test "missing barriers and the end of the data" =
  let times, prices = series [ 100.; 101.; 103.; 99.; 98. ] in
  print
    (Labels.label
       ~times
       ~prices
       { profit_take = None; stop_loss = Some 1.; vertical = None }
       [ event 0; event 1 ]);
  print
    (Labels.label
       ~times
       ~prices
       { profit_take = None
       ; stop_loss = None
       ; vertical = Some (Time_ns.Span.of_int_sec 2)
       }
       [ event 0; event 3 ]);
  [%expect
    {|
    entry 0 -> exit 3 Stop_loss   return -0.0100 label -1
    entry 1 -> exit 3 Stop_loss   return -0.0198 label -1
    entry 0 -> exit 2 Vertical    return +0.0300 label 1
    entry 3 -> exit 4 End_of_data return -0.0101 label -1
    |}]
;;

let%expect_test "volatility-scaled widths" =
  let _, prices = series [ 100.; 101.; 100.; 102.; 101.; 101. ] in
  Labels.ewma_volatility ~prices ~span:3 |> Array.iter ~f:(printf "%.5f ");
  [%expect {| nan 0.01000 0.00995 0.01580 0.01315 0.00930 |}]
;;

let%test_unit "labels agree with their barrier" =
  Quickcheck.test
    ~trials:300
    Quickcheck.Generator.(
      both
        (List.gen_with_length 60 (Float.gen_incl (-0.01) 0.01))
        (List.gen_with_length
           10
           (both
              (Int.gen_incl 0 59)
              (Option.quickcheck_generator Side.Stable.V1.quickcheck_generator))))
    ~sexp_of:[%sexp_of: float list * (int * Side.t option) list]
    ~f:(fun (returns, entries) ->
      let prices =
        List.folding_map returns ~init:100. ~f:(fun p r ->
          let p = p *. (1. +. r) in
          p, p)
      in
      let times, prices = series prices in
      let events =
        List.map entries ~f:(fun (index, side) -> { (event index) with side })
      in
      List.iter (Labels.label ~times ~prices barriers events) ~f:(fun l ->
        assert (l.exit_index >= l.index);
        assert (
          Time_ns.Span.( <= )
            (Time_ns.diff l.exit_time l.entry_time)
            (Time_ns.Span.of_int_sec 4));
        match l.barrier with
        | Profit_take -> assert (Float.( >= ) l.return 0.02)
        | Stop_loss -> assert (Float.( <= ) l.return (-0.01))
        | Vertical | End_of_data ->
          assert (Float.( < ) l.return 0.02 && Float.( > ) l.return (-0.01))))
;;
