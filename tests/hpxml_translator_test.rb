require 'openstudio'
require 'openstudio/ruleset/ShowRunnerOutput'
require 'minitest/autorun'
require_relative '../measure.rb'
require 'fileutils'
require 'json'
require 'rexml/document'
require 'rexml/xpath'
require 'parallel'
require 'etc'
require_relative '../resources/constants'
require_relative '../resources/meta_measure'
require_relative '../resources/unit_conversions'
require_relative '../resources/xmlhelper'

class HPXMLTranslatorTest < MiniTest::Test
  def test_simulations
    OpenStudio::Logger.instance.standardOutLogger.setLogLevel(OpenStudio::Error)
    # OpenStudio::Logger.instance.standardOutLogger.setLogLevel(OpenStudio::Fatal)

    this_dir = File.dirname(__FILE__)
    results_dir = File.join(this_dir, "results")
    _rm_path(results_dir)

    args = {}
    args['weather_dir'] = File.absolute_path(File.join(this_dir, "..", "weather"))
    args['skip_validation'] = false

    dse_dir = File.join(this_dir, "dse")
    cfis_dir = File.join(this_dir, "cfis")
    test_dirs = [this_dir, dse_dir, cfis_dir]

    xmls = []
    test_dirs.each do |test_dir|
      Dir["#{test_dir}/valid*.xml"].sort.each do |xml|
        xmls << File.absolute_path(xml)
      end
    end

    # Test simulations (in parallel)
    puts "Running #{xmls.size} HPXML files..."
    if Process.respond_to?(:fork) # e.g., most Unix systems

      # Setup IO.pipe to communicate output from child processes to this parent process
      readers, writers = {}, {}
      xmls.each do |xml|
        readers[xml], writers[xml] = IO.pipe
      end

      # Do runs in separate processes
      Parallel.map(xmls, in_processes: Parallel.processor_count - 1) do |xml|
        rundir = _run_xml(xml, this_dir, args.dup, Parallel.worker_number)
        sim_results = _get_results(rundir)
        writers[xml].puts(Marshal.dump(sim_results)) # Provide output data to parent process
      end

      # Retrieve output data from child processes
      all_results = {}
      readers.each do |xml, reader|
        writers[xml].close
        all_results[xml] = Marshal.load(reader.read)
      end

    else # e.g., Windows

      # Do runs in separate threads
      all_results = {}
      Parallel.map(xmls, in_threads: Parallel.processor_count - 1) do |xml|
        rundir = _run_xml(xml, this_dir, args.dup, Parallel.worker_number)
        all_results[xml] = _get_results(rundir)
      end

    end

    _write_summary_results(results_dir, all_results)
    _test_dse(dse_dir, all_results)
    _test_cfis(cfis_dir, all_results)
  end

  def _run_xml(xml, this_dir, args, worker_num)
    print "Testing #{File.basename(xml)}...\n"
    rundir = File.join(this_dir, "run#{worker_num}")
    args['epw_output_path'] = File.absolute_path(File.join(rundir, "in.epw"))
    args['osm_output_path'] = File.absolute_path(File.join(rundir, "in.osm"))
    args['hpxml_path'] = xml
    _test_schema_validation(this_dir, xml)
    _test_simulation(args, this_dir, rundir)
    return rundir
  end

  def _get_results(rundir)
    sql_path = File.join(rundir, "eplusout.sql")
    sqlFile = OpenStudio::SqlFile.new(sql_path, false)

    tdws = 'TabularDataWithStrings'
    abups = 'AnnualBuildingUtilityPerformanceSummary'
    ef = 'Entire Facility'
    eubs = 'End Uses By Subcategory'
    s = 'Subcategory'

    # Obtain fueltypes
    query = "SELECT ColumnName FROM #{tdws} WHERE ReportName='#{abups}' AND ReportForString='#{ef}' AND TableName='#{eubs}' and ColumnName!='#{s}'"
    fueltypes = sqlFile.execAndReturnVectorOfString(query).get

    # Obtain units
    query = "SELECT Units FROM #{tdws} WHERE ReportName='#{abups}' AND ReportForString='#{ef}' AND TableName='#{eubs}' and ColumnName!='#{s}'"
    units = sqlFile.execAndReturnVectorOfString(query).get

    # Obtain categories
    query = "SELECT RowName FROM #{tdws} WHERE ReportName='#{abups}' AND ReportForString='#{ef}' AND TableName='#{eubs}' AND ColumnName='#{s}'"
    categories = sqlFile.execAndReturnVectorOfString(query).get
    # Fill in blanks based on previous non-blank value
    full_categories = []
    (0..categories.size - 1).each do |i|
      full_categories << categories[i]
      next if full_categories[i].size > 0

      full_categories[i] = full_categories[i - 1]
    end
    full_categories = full_categories * fueltypes.uniq.size # Expand to size of fueltypes

    # Obtain subcategories
    query = "SELECT Value FROM #{tdws} WHERE ReportName='#{abups}' AND ReportForString='#{ef}' AND TableName='#{eubs}' AND ColumnName='#{s}'"
    subcategories = sqlFile.execAndReturnVectorOfString(query).get
    subcategories = subcategories * fueltypes.uniq.size # Expand to size of fueltypes

    # Obtain starting position of results
    query = "SELECT MIN(TabularDataIndex) FROM #{tdws} WHERE ReportName='#{abups}' AND ReportForString='#{ef}' AND TableName='#{eubs}' AND ColumnName='#{fueltypes[0]}'"
    starting_index = sqlFile.execAndReturnFirstInt(query).get

    # TabularDataWithStrings table is positional, so we access results by position.
    results = {}
    fueltypes.zip(full_categories, subcategories, units).each_with_index do |(fueltype, category, subcategory, fuel_units), index|
      query = "SELECT Value FROM #{tdws} WHERE ReportName='#{abups}' AND ReportForString='#{ef}' AND TableName='#{eubs}' AND TabularDataIndex='#{starting_index + index}'"
      val = sqlFile.execAndReturnFirstDouble(query).get
      next if val == 0

      results[[fueltype, category, subcategory, fuel_units]] = val
    end

    sqlFile.close

    return results
  end

  def _test_simulation(args, this_dir, rundir)
    # Uses meta_measure workflow for faster simulations

    # Setup
    _rm_path(rundir)
    Dir.mkdir(rundir)

    workflow_start = Time.now
    model = OpenStudio::Model::Model.new
    runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)

    # Add measure to workflow
    measures = {}
    measure_subdir = File.absolute_path(File.join(this_dir, "..")).split('/')[-1]
    update_args_hash(measures, measure_subdir, args)

    # Apply measure
    measures_dir = File.join(this_dir, "../../")
    success = apply_measures(measures_dir, measures, runner, model, nil, nil, true)

    # Report warnings/errors
    File.open(File.join(rundir, 'run.log'), 'w') do |f|
      runner.result.stepWarnings.each do |s|
        f << "Warning: #{s}\n"
      end
      runner.result.stepErrors.each do |s|
        f << "Error: #{s}\n"
      end
    end

    assert(success)

    # Write model to IDF
    forward_translator = OpenStudio::EnergyPlus::ForwardTranslator.new
    model_idf = forward_translator.translateModel(model)
    File.open(File.join(rundir, "in.idf"), 'w') { |f| f << model_idf.to_s }

    # Run EnergyPlus
    ep_path = File.absolute_path(File.join(OpenStudio.getOpenStudioCLI.to_s, '..', '..', 'EnergyPlus', 'energyplus'))
    command = "cd #{rundir} && #{ep_path} -w in.epw in.idf > stdout-energyplus"
    simulation_start = Time.now
    system(command, :err => File::NULL)
    puts "Completed #{File.basename(args['hpxml_path'])} simulation in #{(Time.now - simulation_start).round(1)}, workflow in #{(Time.now - workflow_start).round(1)}s."

    # Verify simulation outputs
    _verify_simulation_outputs(rundir, args['hpxml_path'])
  end

  def _verify_simulation_outputs(rundir, hpxml_path)
    sql_path = File.join(rundir, "eplusout.sql")
    assert(File.exists? sql_path)

    sqlFile = OpenStudio::SqlFile.new(sql_path, false)
    hpxml_doc = REXML::Document.new(File.read(hpxml_path))

    bldg_details = hpxml_doc.elements['/HPXML/Building/BuildingDetails']

    # Conditioned Floor Area
    if XMLHelper.has_element(bldg_details, "Systems/HVAC") # EnergyPlus will only report conditioned floor area if there is an HVAC system
      hpxml_value = Float(XMLHelper.get_value(bldg_details, 'BuildingSummary/BuildingConstruction/ConditionedFloorArea'))
      query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='InputVerificationandResultsSummary' AND ReportForString='Entire Facility' AND TableName='Zone Summary' AND RowName='Conditioned Total' AND ColumnName='Area' AND Units='m2'"
      sql_value = UnitConversions.convert(sqlFile.execAndReturnFirstDouble(query).get, 'm^2', 'ft^2')
      assert_in_epsilon(hpxml_value, sql_value, 0.01)
    end

    # Enclosure Roofs
    bldg_details.elements.each('Enclosure/AtticAndRoof/Attics/Attic/Roofs/Roof') do |roof|
      roof_id = roof.elements["SystemIdentifier"].attributes["id"].upcase

      # R-value
      hpxml_value = Float(XMLHelper.get_value(roof, 'Insulation/AssemblyEffectiveRValue'))
      query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnvelopeSummary' AND ReportForString='Entire Facility' AND TableName='Opaque Exterior' AND RowName='#{roof_id}' AND ColumnName='U-Factor with Film' AND Units='W/m2-K'"
      sql_value = 1.0 / UnitConversions.convert(sqlFile.execAndReturnFirstDouble(query).get, 'W/(m^2*K)', 'Btu/(hr*ft^2*F)')
      assert_in_epsilon(hpxml_value, sql_value, 0.07) # TODO: Higher due to outside air film?

      # Net area
      hpxml_value = Float(XMLHelper.get_value(roof, 'Area'))
      bldg_details.elements.each('Enclosure/Skylights/Skylight') do |subsurface|
        next if subsurface.elements["AttachedToRoof"].attributes["idref"].upcase != roof_id

        hpxml_value -= Float(XMLHelper.get_value(subsurface, 'Area'))
      end
      query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnvelopeSummary' AND ReportForString='Entire Facility' AND TableName='Opaque Exterior' AND RowName='#{roof_id}' AND ColumnName='Net Area' AND Units='m2'"
      sql_value = UnitConversions.convert(sqlFile.execAndReturnFirstDouble(query).get, 'm^2', 'ft^2')
      assert_in_epsilon(hpxml_value, sql_value, 0.01)

      # Solar absorptance
      hpxml_value = Float(XMLHelper.get_value(roof, 'SolarAbsorptance'))
      query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnvelopeSummary' AND ReportForString='Entire Facility' AND TableName='Opaque Exterior' AND RowName='#{roof_id}' AND ColumnName='Reflectance'"
      sql_value = 1.0 - sqlFile.execAndReturnFirstDouble(query).get
      assert_in_epsilon(hpxml_value, sql_value, 0.01)

      # Tilt
      hpxml_value = UnitConversions.convert(Math.atan(Float(XMLHelper.get_value(roof, "Pitch")) / 12.0), "rad", "deg")
      query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnvelopeSummary' AND ReportForString='Entire Facility' AND TableName='Opaque Exterior' AND RowName='#{roof_id}' AND ColumnName='Tilt' AND Units='deg'"
      sql_value = sqlFile.execAndReturnFirstDouble(query).get
      assert_in_epsilon(hpxml_value, sql_value, 0.01)
    end

    # Enclosure Foundation Slabs
    bldg_details.elements.each('Enclosure/Foundations/Foundation/Slab') do |slab|
      slab_id = slab.elements["SystemIdentifier"].attributes["id"].upcase

      # Area
      hpxml_value = Float(XMLHelper.get_value(slab, 'Area'))
      query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnvelopeSummary' AND ReportForString='Entire Facility' AND TableName='Opaque Exterior' AND RowName='#{slab_id}' AND ColumnName='Gross Area' AND Units='m2'"
      sql_value = UnitConversions.convert(sqlFile.execAndReturnFirstDouble(query).get, 'm^2', 'ft^2')
      assert_in_epsilon(hpxml_value, sql_value, 0.01)

      # Tilt
      query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnvelopeSummary' AND ReportForString='Entire Facility' AND TableName='Opaque Exterior' AND RowName='#{slab_id}' AND ColumnName='Tilt' AND Units='deg'"
      sql_value = sqlFile.execAndReturnFirstDouble(query).get
      assert_in_epsilon(180.0, sql_value, 0.01)
    end

    # Enclosure Walls
    bldg_details.elements.each('Enclosure/Walls/Wall[extension[ExteriorAdjacentTo="ambient"]] | Enclosure/AtticAndRoof/Attics/Attic/Walls/Wall[extension[ExteriorAdjacentTo="ambient"]]') do |wall|
      wall_id = wall.elements["SystemIdentifier"].attributes["id"].upcase

      # R-value
      hpxml_value = Float(XMLHelper.get_value(wall, 'Insulation/AssemblyEffectiveRValue'))
      query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnvelopeSummary' AND ReportForString='Entire Facility' AND TableName='Opaque Exterior' AND RowName='#{wall_id}' AND ColumnName='U-Factor with Film' AND Units='W/m2-K'"
      sql_value = 1.0 / UnitConversions.convert(sqlFile.execAndReturnFirstDouble(query).get, 'W/(m^2*K)', 'Btu/(hr*ft^2*F)')
      assert_in_epsilon(hpxml_value, sql_value, 0.03)

      # Net area
      hpxml_value = Float(XMLHelper.get_value(wall, 'Area'))
      bldg_details.elements.each('Enclosure/Windows/Window | Enclosure/Doors/Door') do |subsurface|
        next if subsurface.elements["AttachedToWall"].attributes["idref"].upcase != wall_id

        hpxml_value -= Float(XMLHelper.get_value(subsurface, 'Area'))
      end
      query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnvelopeSummary' AND ReportForString='Entire Facility' AND TableName='Opaque Exterior' AND RowName='#{wall_id}' AND ColumnName='Net Area' AND Units='m2'"
      sql_value = UnitConversions.convert(sqlFile.execAndReturnFirstDouble(query).get, 'm^2', 'ft^2')
      assert_in_epsilon(hpxml_value, sql_value, 0.01)

      # Solar absorptance
      hpxml_value = Float(XMLHelper.get_value(wall, 'SolarAbsorptance'))
      query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnvelopeSummary' AND ReportForString='Entire Facility' AND TableName='Opaque Exterior' AND RowName='#{wall_id}' AND ColumnName='Reflectance'"
      sql_value = 1.0 - sqlFile.execAndReturnFirstDouble(query).get
      assert_in_epsilon(hpxml_value, sql_value, 0.01)

      # Tilt
      query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnvelopeSummary' AND ReportForString='Entire Facility' AND TableName='Opaque Exterior' AND RowName='#{wall_id}' AND ColumnName='Tilt' AND Units='deg'"
      sql_value = sqlFile.execAndReturnFirstDouble(query).get
      assert_in_epsilon(90.0, sql_value, 0.01)
    end

    # Enclosure Windows/Skylights
    bldg_details.elements.each('Enclosure/Windows/Window | Enclosure/Skylights/Skylight') do |subsurface|
      subsurface_id = subsurface.elements["SystemIdentifier"].attributes["id"].upcase

      # Area
      hpxml_value = Float(XMLHelper.get_value(subsurface, 'Area'))
      query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnvelopeSummary' AND ReportForString='Entire Facility' AND TableName='Exterior Fenestration' AND RowName='#{subsurface_id}' AND ColumnName='Area of Multiplied Openings' AND Units='m2'"
      sql_value = UnitConversions.convert(sqlFile.execAndReturnFirstDouble(query).get, 'm^2', 'ft^2')
      assert_in_epsilon(hpxml_value, sql_value, 0.01)

      # U-Factor
      hpxml_value = Float(XMLHelper.get_value(subsurface, 'UFactor'))
      query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnvelopeSummary' AND ReportForString='Entire Facility' AND TableName='Exterior Fenestration' AND RowName='#{subsurface_id}' AND ColumnName='Glass U-Factor' AND Units='W/m2-K'"
      sql_value = UnitConversions.convert(sqlFile.execAndReturnFirstDouble(query).get, 'W/(m^2*K)', 'Btu/(hr*ft^2*F)')
      assert_in_epsilon(hpxml_value, sql_value, 0.01)

      # SHGC
      # TODO: Affected by interior shading

      # Azimuth
      hpxml_value = Float(XMLHelper.get_value(subsurface, 'Azimuth'))
      query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnvelopeSummary' AND ReportForString='Entire Facility' AND TableName='Exterior Fenestration' AND RowName='#{subsurface_id}' AND ColumnName='Azimuth' AND Units='deg'"
      sql_value = sqlFile.execAndReturnFirstDouble(query).get
      assert_in_epsilon(hpxml_value, sql_value, 0.01)

      # Tilt
      if XMLHelper.has_element(subsurface, "AttachedToWall")
        query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnvelopeSummary' AND ReportForString='Entire Facility' AND TableName='Exterior Fenestration' AND RowName='#{subsurface_id}' AND ColumnName='Tilt' AND Units='deg'"
        sql_value = sqlFile.execAndReturnFirstDouble(query).get
        assert_in_epsilon(90.0, sql_value, 0.01)
      elsif XMLHelper.has_element(subsurface, "AttachedToRoof")
        hpxml_value = nil
        bldg_details.elements.each('Enclosure/AtticAndRoof/Attics/Attic/Roofs/Roof') do |roof|
          next if roof.elements["SystemIdentifier"].attributes["id"] != subsurface.elements["AttachedToRoof"].attributes["idref"]

          hpxml_value = UnitConversions.convert(Math.atan(Float(XMLHelper.get_value(roof, "Pitch")) / 12.0), "rad", "deg")
        end
        query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnvelopeSummary' AND ReportForString='Entire Facility' AND TableName='Exterior Fenestration' AND RowName='#{subsurface_id}' AND ColumnName='Tilt' AND Units='deg'"
        sql_value = sqlFile.execAndReturnFirstDouble(query).get
        assert_in_epsilon(hpxml_value, sql_value, 0.01)
      else
        flunk "Subsurface '#{subsurface_id}' should have either AttachedToWall or AttachedToRoof element."
      end
    end

    # Enclosure Doors
    bldg_details.elements.each('Enclosure/Doors/Door') do |door|
      door_id = door.elements["SystemIdentifier"].attributes["id"].upcase

      # Area
      hpxml_value = Float(XMLHelper.get_value(door, 'Area'))
      query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnvelopeSummary' AND ReportForString='Entire Facility' AND TableName='Exterior Door' AND RowName='#{door_id}' AND ColumnName='Gross Area' AND Units='m2'"
      sql_value = UnitConversions.convert(sqlFile.execAndReturnFirstDouble(query).get, 'm^2', 'ft^2')
      assert_in_epsilon(hpxml_value, sql_value, 0.01)

      # R-Value
      hpxml_value = Float(XMLHelper.get_value(door, 'RValue'))
      query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnvelopeSummary' AND ReportForString='Entire Facility' AND TableName='Exterior Door' AND RowName='#{door_id}' AND ColumnName='U-Factor with Film' AND Units='W/m2-K'"
      sql_value = 1.0 / UnitConversions.convert(sqlFile.execAndReturnFirstDouble(query).get, 'W/(m^2*K)', 'Btu/(hr*ft^2*F)')
      assert_in_epsilon(hpxml_value, sql_value, 0.01)
    end

    sqlFile.close
  end

  def _write_summary_results(results_dir, results)
    Dir.mkdir(results_dir)
    csv_out = File.join(results_dir, 'results.csv')

    # Get all keys across simulations for output columns
    output_keys = []
    results.each do |xml, xml_results|
      xml_results.keys.each do |key|
        next if output_keys.include? key

        output_keys << key
      end
    end

    column_headers = ['HPXML']
    output_keys.each do |key|
      column_headers << "#{key[0]}: #{key[1]}: #{key[2]} [#{key[3]}]"
    end

    require 'csv'
    CSV.open(csv_out, 'w') do |csv|
      csv << column_headers
      results.each do |xml, xml_results|
        csv_row = [xml]
        output_keys.each do |key|
          if xml_results[key].nil?
            csv_row << 0
          else
            csv_row << xml_results[key]
          end
        end
        csv << csv_row
      end
    end

    puts "Wrote results to #{csv_out}."
  end

  def _test_schema_validation(this_dir, xml)
    # TODO: Remove this when schema validation is included with CLI calls
    schemas_dir = File.absolute_path(File.join(this_dir, "..", "hpxml_schemas"))
    hpxml_doc = REXML::Document.new(File.read(xml))
    errors = XMLHelper.validate(hpxml_doc.to_s, File.join(schemas_dir, "HPXML.xsd"), nil)
    if errors.size > 0
      puts "#{xml}: #{errors.to_s}"
    end
    assert_equal(0, errors.size)
  end

  def _test_dse(dse_dir, all_results)
    # DSE tests
    # Compare heating/cooling results to files with no ducts.
    Dir["#{dse_dir}/unvalid*.xml"].sort.each do |xml|
      xml_dse = File.absolute_path(xml)
      results_dse = all_results[xml_dse]

      # Retrieve no distribution results for comparison
      xml_nodist = File.absolute_path(File.join(File.dirname(xml), "..", File.basename(xml.gsub("-dse", "-no-distribution"))))
      results_nodist = all_results[xml_nodist]

      # Compare results
      puts "\nResults for #{File.basename(xml)}:"
      results_dse.keys.each do |k|
        next if not ["Heating", "Cooling"].include? k[1]

        result_dse = results_dse[k].to_f
        result_nodist = results_nodist[k].to_f
        next if result_dse == 0.0 and result_nodist == 0.0

        dse_actual = result_nodist / result_dse
        dse_expect = 0.8
        puts "dse: #{dse_actual.round(2)} #{k}"
        assert_in_epsilon(dse_expect, dse_actual, 0.025)
      end
      puts "\n"
    end
  end

  def _test_cfis(cfis_dir, all_results)
    # CFIS tests
    # Verify non-zero mechanical ventilation energy.
    Dir["#{cfis_dir}/valid*.xml"].sort.each do |xml|
      xml_cfis = File.absolute_path(xml)
      results_cfis = all_results[xml_cfis]

      # Verify results
      puts "\nResults for #{File.basename(xml)}:"
      found_mv = false
      results_cfis.keys.each do |k|
        next if k[0] != 'Electricity' or k[2] != Constants.EndUseMechVentFan

        found_mv = true
        puts "CFIS: #{results_cfis[k].round(2)} #{k}"
        assert_operator(results_cfis[k], :>, 0)
      end
      assert(found_mv)
    end
  end

  def _rm_path(path)
    if Dir.exists?(path)
      FileUtils.rm_r(path)
    end
    while true
      break if not Dir.exists?(path)

      sleep(0.01)
    end
  end
end
