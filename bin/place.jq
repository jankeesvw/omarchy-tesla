# Nominatim reverse jsonv2 → glance-line contract.
# Address fields come from .address. display_name is a sibling and must not leak.
.address as $a
| ($a.road // $a.pedestrian // $a.footway // "") as $road
| ($a.house_number // "") as $number
| ($a.village // $a.town // $a.city // $a.suburb // $a.municipality // "") as $locality
| (($a.country_code // "") | ascii_downcase) as $cc
| (["us", "ca", "gb", "ie", "au", "nz", "fr"] | index($cc) != null) as $number_first
| (["us", "ca", "au"] | index($cc) != null) as $want_region
| ($a["ISO3166-2-lvl4"] // "") as $iso
| (if ($iso | type == "string") and ($iso | test("-"))
   then ($iso | sub("^[^-]*-"; ""))
   else "" end) as $region
| (if $want_region and ($locality != "") and ($region != "")
   then $locality + ", " + $region
   else $locality end) as $town
| (if $number_first and ($number != "") and ($road != "")
   then $number + " " + $road
   else ([$road, $number] | map(select(. != "")) | join(" "))
   end) as $head
| {ok: true,
   street: $road,
   number: $number,
   town: $town,
   number_first: $number_first,
   place: ([$head, $town] | map(select(. != "")) | join(", "))}
