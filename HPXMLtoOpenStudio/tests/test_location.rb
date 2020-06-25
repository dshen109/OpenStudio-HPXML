# frozen_string_literal: true

require_relative '../resources/minitest_helper'
require 'openstudio'
require 'openstudio/ruleset/ShowRunnerOutput'
require 'minitest/autorun'
require 'fileutils'
require_relative '../measure.rb'
require_relative '../resources/util.rb'

class HPXMLtoOpenStudioLocationTest < MiniTest::Test
  def sample_files_dir
    return File.join(File.dirname(__FILE__), '..', '..', 'workflow', 'sample_files')
  end

  def get_run_period_month_and_days(model)
    run_period = model.getRunPeriod
    begin_month = run_period.getBeginMonth
    begin_day_of_month = run_period.getBeginDayOfMonth
    end_month = run_period.getEndMonth
    end_day_of_month = run_period.getEndDayOfMonth
    return begin_month, begin_day_of_month, end_month, end_day_of_month
  end

  def get_daylight_saving_month_and_days(model)
    run_period_control_daylight_saving_time = model.getRunPeriodControlDaylightSavingTime
    start_date = run_period_control_daylight_saving_time.startDate
    end_date = run_period_control_daylight_saving_time.endDate
    begin_month = start_date.monthOfYear.value
    begin_day_of_month = start_date.dayOfMonth
    end_month = end_date.monthOfYear.value
    end_day_of_month = end_date.dayOfMonth
    return begin_month, begin_day_of_month, end_month, end_day_of_month
  end

  def test_run_period
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base.xml'))
    model, hpxml = _test_measure(args_hash)

    begin_month, begin_day_of_month, end_month, end_day_of_month = get_run_period_month_and_days(model)

    assert_equal(1, begin_month)
    assert_equal(1, begin_day_of_month)
    assert_equal(12, end_month)
    assert_equal(31, end_day_of_month)

    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-misc-runperiod-1-month.xml'))
    model, hpxml = _test_measure(args_hash)

    begin_month, begin_day_of_month, end_month, end_day_of_month = get_run_period_month_and_days(model)

    assert_equal(1, begin_month)
    assert_equal(1, begin_day_of_month)
    assert_equal(1, end_month)
    assert_equal(31, end_day_of_month)
  end

  def test_daylight_saving
    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base.xml'))
    model, hpxml = _test_measure(args_hash)

    begin_month, begin_day_of_month, end_month, end_day_of_month = get_daylight_saving_month_and_days(model)

    assert_equal(3, begin_month)
    assert_equal(11, begin_day_of_month)
    assert_equal(11, end_month)
    assert_equal(4, end_day_of_month)

    args_hash = {}
    args_hash['hpxml_path'] = File.absolute_path(File.join(sample_files_dir, 'base-location-epw-filepath-AMY-2012-dst.xml'))
    model, hpxml = _test_measure(args_hash)

    begin_month, begin_day_of_month, end_month, end_day_of_month = get_daylight_saving_month_and_days(model)

    assert_equal(3, begin_month)
    assert_equal(12, begin_day_of_month)
    assert_equal(11, end_month)
    assert_equal(6, end_day_of_month)
  end

  def _test_measure(args_hash)
    # create an instance of the measure
    measure = HPXMLtoOpenStudio.new

    runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)
    model = OpenStudio::Model::Model.new

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # populate argument with specified hash value if specified
    arguments.each do |arg|
      temp_arg_var = arg.clone
      if args_hash.has_key?(arg.name)
        assert(temp_arg_var.setValue(args_hash[arg.name]))
      end
      argument_map[arg.name] = temp_arg_var
    end

    # run the measure
    measure.run(model, runner, argument_map)
    result = runner.result

    # show the output
    show_output(result) unless result.value.valueName == 'Success'

    # assert that it ran correctly
    assert_equal('Success', result.value.valueName)

    hpxml = HPXML.new(hpxml_path: args_hash['hpxml_path'])

    return model, hpxml
  end
end
