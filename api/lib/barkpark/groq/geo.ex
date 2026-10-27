defmodule Barkpark.Groq.Geo do
  @moduledoc """
  GROQ's `geo::latLng/2` and `geo::distance/2`, as Sanity answers them
  (task-ce93ff890a895f54; /papers/groq-remaining-functions).

  A geo value is `{:geo, lat, lng}`: opaque inside a query, as on Sanity
  (`.lat` and `.coordinates` read null, `==` is false), and rendered as a
  GeoJSON Point `{"type": "Point", "coordinates": [lng, lat]}`
  (`Barkpark.Groq.Values.to_json/1`).

  `distance/2` is the haversine distance in metres on Sanity's sphere,
  R = 6,378,137 m: one degree along the equator is 111319.49079327357 and pole
  to pole is 20037508.342789244, both measured against Sanity. It takes a geo
  value, a Sanity geopoint object (`lat`/`lng`, with or without `_type`) or a
  GeoJSON Point, and answers null for anything else, a point out of range
  included.
  """

  @radius 6_378_137

  @doc "A geo point, or nil unless `lat` and `lng` are numbers in range."
  def lat_lng(lat, lng) do
    if in_range?(lat, lng), do: {:geo, lat, lng}, else: nil
  end

  @doc "The haversine distance in metres between two points, or nil."
  def distance(a, b) do
    with {lat1, lng1} <- point(a),
         {lat2, lng2} <- point(b) do
      # The atan2 form of haversine (as in S2's LatLng.Distance): it lands on
      # Sanity's doubles exactly for the cases measured, the asin form a ulp off.
      {lat1, lat2} = {rad(lat1), rad(lat2)}
      dlat = :math.sin(0.5 * (lat2 - lat1))
      dlng = :math.sin(0.5 * (rad(lng2) - rad(lng1)))
      x = dlat * dlat + dlng * dlng * :math.cos(lat1) * :math.cos(lat2)
      2 * :math.atan2(:math.sqrt(x), :math.sqrt(max(0.0, 1 - x))) * @radius
    end
  end

  @doc "The GeoJSON a geo value renders as."
  def to_json({:geo, lat, lng}), do: %{"type" => "Point", "coordinates" => [lng, lat]}

  defp point({:geo, lat, lng}), do: {lat, lng}

  defp point(%{"type" => "Point", "coordinates" => [lng, lat | _]}),
    do: if(in_range?(lat, lng), do: {lat, lng})

  defp point(%{"lat" => lat, "lng" => lng}), do: if(in_range?(lat, lng), do: {lat, lng})
  defp point(_), do: nil

  defp in_range?(lat, lng),
    do: is_number(lat) and is_number(lng) and abs(lat) <= 90 and abs(lng) <= 180

  defp rad(deg), do: deg * (:math.pi() / 180)
end
