class Constants
  def self.CoordRelative
    return 'relative'
  end

  # Numbers --------------------

  def self.MaxNumPhotovoltaics
    return 2
  end

  def self.MaxNumPlugLoads
    return 2
  end

  def self.NumDaysInMonths(is_leap_year = false)
    num_days_in_months = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    num_days_in_months[1] += 1 if is_leap_year
    return num_days_in_months
  end

  def self.NumDaysInYear(is_leap_year = false)
    num_days_in_months = NumDaysInMonths(is_leap_year)
    num_days_in_year = num_days_in_months.reduce(:+)
    return num_days_in_year.to_f
  end

  def self.NumHoursInYear(is_leap_year = false)
    num_days_in_year = NumDaysInYear(is_leap_year)
    num_hours_in_year = num_days_in_year * 24
    return num_hours_in_year.to_f
  end

  def self.NumApplyUpgradeOptions
    return 25
  end

  def self.NumApplyUpgradesCostsPerOption
    return 2
  end
end