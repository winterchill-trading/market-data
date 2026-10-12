open! Core
open! Async

module type S = sig
  val trades : Trade.t Pipe.Reader.t
  val bbo : Bbo.t Pipe.Reader.t
  val l2 : L2_update.t Pipe.Reader.t
  val funding : Funding.t Pipe.Reader.t
  val close : unit -> unit Deferred.t
end

type t = (module S)

module With_gaps = struct
  module type S = sig
    include S

    val gaps : Gap.t Pipe.Reader.t
  end

  type feed = t
  type t = (module S)

  let to_feed (module F : S) : feed = (module F)

  let of_feed ((module F) : feed) : t =
    let gaps, gaps_w = Pipe.create () in
    upon
      (Deferred.all_unit
         [ Pipe.closed F.trades
         ; Pipe.closed F.bbo
         ; Pipe.closed F.l2
         ; Pipe.closed F.funding
         ])
      (fun () -> Pipe.close gaps_w);
    (module struct
      include F

      let gaps = gaps

      let close () =
        Pipe.close gaps_w;
        F.close ()
      ;;
    end)
  ;;
end
