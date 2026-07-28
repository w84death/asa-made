# Osaka Loop Route — engine data bundle

This bundle extracts the **Hanshin Expressway Route 1 Loop Route** in central Osaka from OpenStreetMap relation **6085197**, plus building footprints within a **150 m horizontal corridor**.

## Best files to start with

| File | Use |
| --- | --- |
| `engine/loop_scene_local.json` | Engine-neutral scene data in local metres. Positions are `[x,y,z]`: east, up, north. |
| `engine/route_centerline_local.csv` | Closed clockwise spline with cumulative distance. |
| `engine/loop_route_massing.obj` | Immediate graybox: approximate extruded buildings and a flat 10 m-wide route preview. |
| `geojson/route_centerline_wgs84.geojson` | Clean 10.342 km mainline in EPSG:4326. |
| `geojson/route_segments_wgs84.geojson` | All relation members with mainline, ramp/connector roles, and OSM road tags. |
| `geojson/buildings_150m_wgs84.geojson` | Georeferenced building footprints and height metadata. |

## Coordinate system

- Source: WGS84 / EPSG:4326.
- Local origin: longitude **135.50396305**, latitude **34.67513155**, altitude 0 m.
- Local axes: **X east, Y up, Z north**, in metres.
- Unity commonly uses X east / Y up / Z north directly. If your world convention treats positive Z as south, negate Z on import.

## What was separated

The OSM relation contains 31 member ways. Only the 18 ways tagged with relation role `forward` form the clean mainline; together they measure **10341.93 m**, matching the published 10.3 km length. Other relation members remain in `route_segments_wgs84.geojson` as ramps/connectors and are not merged into the centerline.

## Building heights

There are **7,223** building features. **937** have an OSM `height` or `building:levels` value. For the quick OBJ only, missing heights use a conservative type-based fallback (usually 10 m). The original height source and fallback are explicit in GeoJSON and local JSON.

## Important 3D limitations

- The horizontal route alignment and building footprint shapes are real map geometry.
- OSM does not provide an authoritative continuous road-deck elevation, banking/crossfall, lane-edge survey, or terrain surface here.
- The OBJ route is therefore a **flat 10 m-wide preview**, not a drivable final mesh.
- For a driving track, use the local CSV/JSON as a spline, then author elevation, banking, road width, barriers, junction transitions, and collision from reference imagery or survey/LiDAR.
- Building massing is suitable for blockout and skyline context; it is not façade reconstruction.

## Suggested engine workflow

1. Import `route_centerline_local.csv` or `loop_scene_local.json` as a closed clockwise spline.
2. Generate a road ribbon along the spline; start near 10 m and tune per segment using the lane tags in `route_segments_wgs84.geojson`.
3. Import the OBJ for instant context, or extrude the local building footprints yourself to retain stable object IDs.
4. Add a DEM or LiDAR source before final vertical placement.

## Source and licensing

Route and buildings: **© OpenStreetMap contributors**, made available under the **Open Database License (ODbL) 1.0**. Preserve attribution when using or redistributing derived data. The exact source snapshots and counts are recorded in `metadata.json`; raw source responses are kept under `sources/`.

- OSM relation: https://www.openstreetmap.org/relation/6085197
- ODbL: https://opendatacommons.org/licenses/odbl/1-0/
