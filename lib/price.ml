open! Core

module Bin =
  Binable.Of_binable_without_uuid [@alert "-legacy"]
    (Int)
    (struct
      type t = Exchange_core.Price.t

      let to_binable = Exchange_core.Price.to_units
      let of_binable = Exchange_core.Price.of_units
    end)

module Stable = struct
  module V1 = struct
    include Exchange_core.Price
    include Bin
  end
end

include Exchange_core.Price
include Bin
