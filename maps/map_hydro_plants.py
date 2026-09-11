"""Plot California hydro plant locations as a static, report-ready image
showing the California outline."""

import textwrap

import truststore

truststore.inject_into_ssl()  # use OS trust store for corporate proxy/VPN certs

import contextily as ctx
import geopandas as gpd
import matplotlib.pyplot as plt
import matplotlib.patheffects as pe

# Public domain US state boundaries GeoJSON, commonly used for outline maps.
US_STATES_URL = (
    "https://raw.githubusercontent.com/PublicaMundi/MappingAPI/master/"
    "data/geojson/us-states.json"
)


def dms_to_decimal(degrees, minutes, seconds, direction):
    """Convert degrees/minutes/seconds coordinates to decimal degrees."""
    decimal = degrees + minutes / 60 + seconds / 3600
    if direction in ("S", "W"):
        decimal *= -1
    return decimal


PLANTS = {
    "Shasta": (dms_to_decimal(40, 43, 6.82, "N"), dms_to_decimal(122, 25, 9.24, "W")),
    "Mammoth Pool": (dms_to_decimal(37, 19, 22.79, "N"), dms_to_decimal(119, 18, 58.45, "W")),
    "Devil Canyon": (dms_to_decimal(34, 12, 16.16, "N"), dms_to_decimal(117, 20, 4.96, "W")),
}

# Six most populous California cities, (lat, lon).
TOP_CITIES = {
    "Los Angeles": (34.0522, -118.2437),
    "San Diego": (32.7157, -117.1611),
    "San Jose": (37.3382, -121.8863),
    "San Francisco": (37.7749, -122.4194),
    "Fresno": (36.7378, -119.7871),
    "Sacramento": (38.5816, -121.4944),
}


def build_static_map():
    """Create a static satellite image of California with labeled plants and top cities."""
    states = gpd.read_file(US_STATES_URL)
    california = states[states["name"] == "California"].to_crs(epsg=3857)

    # Render at the final report width so text remains readable when placed at 100%.
    fig, ax = plt.subplots(figsize=(2.5, 10 / 3), dpi=300)
    california.boundary.plot(ax=ax, color="white", linewidth=1.25)

    def plot_points(points, color, marker, markersize, fontsize, weight, label_offsets=None):
        label_offsets = label_offsets or {}
        for name, (lat, lon) in points.items():
            point = gpd.GeoSeries(
                gpd.points_from_xy([lon], [lat]), crs="EPSG:4326"
            ).to_crs(epsg=3857)
            x, y = point.x.iloc[0], point.y.iloc[0]
            ax.plot(x, y, marker=marker, color=color, markersize=markersize)
            ax.annotate(
                name,
                xy=(x, y),
                xytext=label_offsets.get(name, (5, 5)),
                textcoords="offset points",
                fontsize=fontsize,
                color="white",
                weight=weight,
                path_effects=[
                    pe.withStroke(linewidth=2.25, foreground="#111111")
                ],
            )

    plot_points(
        PLANTS,
        color="#ff3b30",
        marker="o",
        markersize=5.5,
        fontsize=8.5,
        weight="bold",
        label_offsets={"Shasta": (-5, 5), "Mammoth Pool": (-5, 5), "Devil Canyon": (-5, 5)},
    )
    '''
    plot_points(
        TOP_CITIES,
        color="cyan",
        marker="s",
        markersize=4,
        fontsize=7,
        weight="normal",
        label_offsets={"Los Angeles": (5, -12)},
    )
    '''

    ctx.add_basemap(
        ax,
        source=ctx.providers.Esri.WorldImagery,
        crs=california.crs,
        attribution=False,
    )

    ax.set_axis_off()
    fig.subplots_adjust(left=0, right=1, bottom=0.035, top=1)
    fig.text(
        0.5,
        0.004,
        textwrap.fill(ctx.providers.Esri.WorldImagery.attribution, width=75),
        ha="center",
        va="bottom",
        fontsize=3.5,
        color="#333333",
        linespacing=1.0,
    )

    return fig


if __name__ == "__main__":
    static_fig = build_static_map()
    static_output_path = "california_hydro_plants.png"
    static_fig.savefig(static_output_path, dpi=300)
    print(f"Static map saved to {static_output_path}")
