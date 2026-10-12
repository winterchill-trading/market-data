open! Core

module Bin =
  Binable.Of_binable_without_uuid [@alert "-legacy"]
    (Int)
    (struct
      type t = Exchange_core.Size.t

      let to_binable = Exchange_core.Size.to_units
      let of_binable = Exchange_core.Size.of_units
    end)

module Stable = struct
  module V1 = struct
    include Exchange_core.Size
    include Bin

    let quickcheck_generator =
      Quickcheck.Generator.map
        (Int.gen_incl (-1_000_000_000_000) 1_000_000_000_000)
        ~f:of_units
    ;;

    let quickcheck_observer =
      Quickcheck.Observer.unmap Int.quickcheck_observer ~f:to_units
    ;;

    let quickcheck_shrinker = Quickcheck.Shrinker.empty ()
  end
end

include Exchange_core.Size
include Bin
