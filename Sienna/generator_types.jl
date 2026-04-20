"""Contains all the mappings for generator data parsing from MATPOWER format."""

const PM_TYPE_DICT = Dict{String, PSY.PrimeMovers}(
    "Conventional Hydroelectric" => PrimeMovers.HA,
    "Hydroelectric Pumped Storage" => PrimeMovers.HY,

    "Solar Photovoltaic" => PrimeMovers.PVe,
    "Solar Thermal without Energy Storage" => PrimeMovers.PVe,

    "Onshore Wind Turbine" => PrimeMovers.WT,

    "Batteries" => PrimeMovers.BA,

    "Municipal Solid Waste" => PrimeMovers.ST,
    "Other Waste Biomass" => PrimeMovers.ST,
    "Petroleum Liquids" => PrimeMovers.IC,
    "Geothermal" => PrimeMovers.ST,
    "Nuclear" => PrimeMovers.ST,
    "Wood/Wood Waste Biomass" => PrimeMovers.ST,
    "Conventional Steam Coal" => PrimeMovers.ST,
    "Petroleum Coke" => PrimeMovers.ST,
    "Natural Gas Fired Combustion Turbine" => PrimeMovers.GT,
    "Natural Gas Internal Combustion Engine" => PrimeMovers.IC,
    "Natural Gas Fired Combined Cycle" => PrimeMovers.CT,
    "Natural Gas Steam Turbine" => PrimeMovers.ST,
    "Other Natural Gas" => PrimeMovers.OT,

    # no prime mover type--handled as SynchronousCondenser and Source structs--but still
    # included here for code flow simplicity.
    "Synchronous Condenser" => PrimeMovers.OT,
    "IMPORT" => PrimeMovers.OT,

    "All Other" => PrimeMovers.OT,
    "Landfill Gas" => PrimeMovers.OT,
    "Other Gases" => PrimeMovers.OT
)

const RAMP_LIMIT_DICT = Dict(
    (PrimeMovers.ST, ThermalFuels.COAL) => (up = 0.00264, down = 0.00264),

    (PrimeMovers.CA, ThermalFuels.NATURAL_GAS) => (up = 0.0042, down = 0.0042),
    (PrimeMovers.CT, ThermalFuels.NATURAL_GAS) => (up = 0.14, down = 0.14),
    (PrimeMovers.GT, ThermalFuels.NATURAL_GAS) => (up = 0.2475, down = 0.2475),
    (PrimeMovers.ST, ThermalFuels.NATURAL_GAS) => (up = 0.0054, down = 0.0054),

    (PrimeMovers.OT, ThermalFuels.NUCLEAR) => (up = 0.0001, down = 0.0001),
    (PrimeMovers.OT, ThermalFuels.GEOTHERMAL) => (up = 0.01, down = 0.01),
)

const PSY_TO_WECC_DICT = Dict(
    (PrimeMovers.ST, ThermalFuels.COAL) => "CLLIG",

    (PrimeMovers.CA, ThermalFuels.NATURAL_GAS) => "CC",
    (PrimeMovers.CT, ThermalFuels.NATURAL_GAS) => "SC",
    (PrimeMovers.GT, ThermalFuels.NATURAL_GAS) => "SC",
    (PrimeMovers.ST, ThermalFuels.NATURAL_GAS) => "GS",
    # not from WECC: my own invented abbreviations.
    (PrimeMovers.ST, ThermalFuels.GEOTHERMAL) => "GEO",
    (PrimeMovers.ST, ThermalFuels.NUCLEAR) => "NUC",
)


function get_size(WECC_key::String, maxPower::Float64)
    if WECC_key in ("CC", "SC")
        if maxPower <= 90
            return "LE90"
        else
            return "GT90"
        end
    elseif WECC_key in ("GEO", "NUC")
        return "ANY"
    elseif WECC_key == "CLLIG"
        if maxPower <= 300
            return "SMALL"
        elseif maxPower <= 900
            return "LARGE"
        else
            return "SUPER"
        end
    elseif WECC_key == "GS"
        return "REH"  # default to reheat
    end
    @assert false "Unexpected input to get_size: $WECC_key, $maxPower"
    return "NONE"
end

const DURATION_LIMIT_DICT = Dict(
    ("CLLIG", "SMALL") => (up = 12.0, down = 6.0), # Coal and Lignite -> WECC (1) Small coal
    ("CLLIG", "LARGE") => (up = 12.0, down = 8.0), # WECC (2) Large coal
    ("CLLIG", "SUPER") => (up = 24.0, down = 8.0), # WECC (3) Super-critical coal
    ("CC", "GT90") => (up = 2.0, down = 6.0), # Combined cycle greater than 90 MW -> WECC (7) Typical CC
    ("CC", "LE90") => (up = 2.0, down = 4.0), # Combined cycle less than 90 MW -> WECC (7) Typical CC, modified
    ("GS", "NONR") => (up = 2.0, down = 4.0), # Gas steam non-reheat -> WECC (4) Gas-fired steam (sub- and super-critical)
    ("GS", "REH") => (up = 2.0, down = 4.0), # Gas steam reheat boiler -> WECC (4) Gas-fired steam (sub- and super-critical)
    ("GS", "SUP") => (up = 2.0, down = 4.0), # Gas-steam supercritical -> WECC (4) Gas-fired steam (sub- and super-critical)
    ("SC", "GT90") => (up = 1.0, down = 1.0), # Simple-cycle greater than 90 MW -> WECC (5) Large-frame Gas CT
    ("SC", "LE90") => (up = 1.0, down = 0.0), # Simple-cycle less than 90 MW -> WECC (6) Aero derivative CT
    # not from WECC: numbers are ballpark estimates given by Jose.
    ("GEO", "ANY") => (up = 1000, down = 300),
    ("NUC", "ANY") => (up = 8000, down = 8000),
)

const OTHER_TYPES = ("Synchronous Condenser", "IMPORT", "All Other")

const FUELS_DICT = Dict(
    # simpler to handle Natural Gas types by looking for "Natural Gas" substring
    "Municipal Solid Waste" => ThermalFuels.MUNICIPAL_WASTE,
    "Other Waste Biomass" => ThermalFuels.MUNICIPAL_WASTE,
    "Petroleum Liquids" => ThermalFuels.RESIDUAL_FUEL_OIL,
    "Geothermal" => ThermalFuels.GEOTHERMAL,
    "Nuclear" => ThermalFuels.NUCLEAR,
    "Wood/Wood Waste Biomass" => ThermalFuels.WOOD_WASTE_SOLIDS,
    "Conventional Steam Coal" => ThermalFuels.COAL,
    "Petroleum Coke" => ThermalFuels.PETROLEUM_COKE,
    "Landfill Gas" => ThermalFuels.MUNICIPAL_WASTE,
    "Other Gases" => ThermalFuels.OTHER_GAS
)
