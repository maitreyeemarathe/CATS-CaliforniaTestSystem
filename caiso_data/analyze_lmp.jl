using CSV, DataFrames, Statistics

lmp_filenames = ["JBBLACK2_7_B1_2025_lmp_data.csv", "MAMOTH1G_7_B1_2025_lmp_data.csv", "DVLCYN3G_7_B1_2025_lmp_data.csv"]
for lmp_filename in lmp_filenames
    df_lmp = CSV.read(lmp_filename, DataFrame, select=[:Time, :LMP])
    mean_daily_max = mean(maximum.(Iterators.partition(df_lmp.LMP, 24)))
    println("Mean daily max for $(lmp_filename): ", mean_daily_max)
    median_daily_max = median(maximum.(Iterators.partition(df_lmp.LMP, 24)))
    println("Median daily max for $(lmp_filename): ", median_daily_max)
    mean_daily_min = mean(minimum.(Iterators.partition(df_lmp.LMP, 24)))
    println("Mean daily min for $(lmp_filename): ", mean_daily_min)
    median_daily_min = median(minimum.(Iterators.partition(df_lmp.LMP, 24)))
    println("Median daily min for $(lmp_filename): ", median_daily_min)
end

shadowprices_filenames = ["shadow_prices.csv","shadow_prices_old.csv"]
for filename in shadowprices_filenames
    df_shadowprices = CSV.read(filename, DataFrame)
    shadow_mean_daily_max = mean(maximum.(Iterators.partition(df_shadowprices.value, 24)))
    println("Mean daily max for $(filename): ", shadow_mean_daily_max)
    shadow_median_daily_max = median(maximum.(Iterators.partition(df_shadowprices.value, 24)))
    println("Median daily max for $(filename): ", shadow_median_daily_max)
    shadow_mean_daily_min = mean(minimum.(Iterators.partition(df_shadowprices.value, 24)))
    println("Mean daily min for $(filename): ", shadow_mean_daily_min)
    shadow_median_daily_min = median(minimum.(Iterators.partition(df_shadowprices.value, 24)))
    println("Median daily min for $(filename): ", shadow_median_daily_min)
end