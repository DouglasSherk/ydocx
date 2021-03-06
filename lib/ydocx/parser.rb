#!/usr/bin/env ruby
# encoding: utf-8

require 'nokogiri'
require 'htmlentities'
require 'ydocx/markup_method'
require 'ydocx/elements'
require 'roman-numerals'
require 'murmurhash3'

module YDocx
  class Parser
    attr_accessor :images, :result, :space
    def initialize(doc, rel, rel_files, image_url = '')
      @doc = Nokogiri::XML.parse(doc)
      @rel = Nokogiri::XML.parse(rel)
      @rel_files = rel_files
      @style_nodes = {}
      @styles = {}
      @theme_fonts = {}
      @numbering_desc = {}
      @numbering_count = {}
      @cur_footnote = 1
      @footnote_fmt = 'decimal'
      @cur_endnote = 1
      @endnote_fmt = 'lowerRoman'
      @coder = HTMLEntities.new
      @images = []
      @result = ParsedDocument.new
      @image_path = 'images'
      @image_url = image_url
      @image_style = ''
      init
      if block_given?
        yield self
      end
    end
    
    def init
    end
    
    def get_bool(node)
      return !node.nil? && (node['w:val'].nil? || node['w:val'] == 'true' || node['w:val'] == '1')
    end
    
    def format_number(num, type)
      case type
      when 'decimalZero'
        sprintf("%02d", num)
      when 'upperRoman'
        RomanNumerals.to_roman(num)
      when 'lowerRoman'
        RomanNumerals.to_roman(num).downcase
      when 'upperLetter'
        letter = (num-1) % 26
        rep = (num-1) / 26 + 1
        (letter + 65).chr * rep
      when 'lowerLetter'
        letter = (num-1) % 26
        rep = (num-1) / 26 + 1
        (letter + 97).chr * rep
      # todo: idk
      # when 'ordinal'
      # when 'cardinalText'
      # when 'ordinalText'
      when 'bullet'
        '&bull;'
      else
        num.to_s
      end
    end
    
    def node_style(node)
      style = Style.new
      
      node.children.each do |prop|
        if prop.name == 'pPr'
          if numpr = prop.at_xpath('w:numPr')
            numpr.children.each do |child|
              if child.name == 'ilvl'
                style.ilvl = child['w:val'].to_i
              end
              if child.name == 'numId'
                style.numid = child['w:val'].to_i
              end
            end
          end
        end
        
        if prop.name == 'rPr'
          prop.children.each do |child|
            if child.name == 'rStyle'
              style.apply(@styles[child['w:val']])
            end
            if ['b', 'i', 'caps', 'smallCaps'].include? child.name
              style.instance_variable_set("@#{child.name}".to_sym, get_bool(child))
            end
            if !style.strike && (child.name == 'strike' || child.name == 'dstrike')
              style.strike = get_bool(child)
            end
            if child.name == 'u'
              style.u = child['w:val'] != 'none' # TODO there are other types of underlines
            end
            if child.name == 'vertAlign'
              style.valign = child['w:val']
            end
            if child.name == 'rFonts'
              if !child['w:ascii'].nil?
                style.font = child['w:ascii']
              elsif !child['w:asciiTheme'].nil?
                theme = child['w:asciiTheme'][0, 5]
                style.font = @theme_fonts[theme]
              end
            end
            if child.name == 'sz'
              style.sz = child['w:val'].to_i
            end
            if child.name == 'color'
              style.color = child['w:val']
            end
          end
        end
      end
      style
    end
    
    def compute_style(id)
      node = @style_nodes[id]
      if @styles.has_key?(id)
        @styles[id]
      else
        if based = node.at_xpath('w:basedOn')
          style = compute_style(based['w:val'])
        else
          style = Style.new
        end
        @styles[id] = style.dup
        @styles[id].apply(node_style(node))
      end
    end
    
    def parse
      if settings_file = @rel_files.select { |file| file[:type] =~ /relationships\/settings$/ }.first
        settings_xml = Nokogiri::XML.parse(settings_file[:stream])
        if fpr = settings_xml.at_xpath('//w:settings//w:footnotePr')
          if start = fpr.at_xpath('w:numStart')
            @cur_footnote = start['w:val'].to_i
          end
          if fmt = fpr.at_xpath('w:numFmt')
            @footnote_fmt = fmt['w:val']
          end
        end
        if epr = settings_xml.at_xpath('//w:settings//w:endnotePr')
          if start = epr.at_xpath('w:numStart')
            @cur_endnote = start['w:val'].to_i
          end
          if fmt = epr.at_xpath('w:numFmt')
            @endnote_fmt = fmt['w:val']
          end
        end
      end
    
      if theme_file = @rel_files.select { |file| file[:type] =~ /relationships\/theme$/ }.first
        theme_xml = Nokogiri::XML.parse(theme_file[:stream])
        ['major', 'minor'].each do |type|
          if font = theme_xml.at_xpath(".//a:#{type}Font//a:latin")
            @theme_fonts[type] = font['typeface']
          end
        end
      end
      
      if style_file = @rel_files.select { |file| file[:type] =~ /relationships\/styles$/ }.first
        style_xml = Nokogiri::XML.parse(style_file[:stream])
        style_xml.xpath('//w:styles//w:style').each do |style|
          @style_nodes[style['w:styleId']] = style
        end
        @default_style = Style.new()
        if def_style = style_xml.at_xpath('//w:styles//w:docDefaults//w:rPrDefault')
          @default_style = node_style(def_style)
        end
      end
      
      @style_nodes.keys.each do |id|
        compute_style(id)
      end
      
      if num_file = @rel_files.select { |file| file[:type] =~ /relationships\/numbering$/ }.first
        num_xml = Nokogiri::XML.parse(num_file[:stream])
        abstract_nums = {}
        num_xml.xpath('//w:numbering//w:abstractNum').each do |abstr|
          abstract_nums[abstr['w:abstractNumId']] = abstr
        end
        num_xml.xpath('//w:numbering//w:num').each do |num|
          num_id = num['w:numId'].to_i
          @numbering_desc[num_id] = {}
          @numbering_count[num_id] = {}
          num.xpath('w:abstractNumId').each do |abstr|
            if abstract_nums.has_key?(abstr['w:val'])
              abstract_nums[abstr['w:val']].xpath('w:lvl').each do |lvl|
                indent_level = lvl['w:ilvl'].to_i
                @numbering_count[num_id][indent_level] = 0
                @numbering_desc[num_id][indent_level] = {
                  :start  => lvl.at_xpath('w:start')['w:val'].to_i,
                  :numFmt => lvl.at_xpath('w:numFmt')['w:val'],
                  :format => lvl.at_xpath('w:lvlText')['w:val'],
                  :isLgl  => get_bool(lvl.at_xpath('w:isLgl')),
                  :style  => node_style(lvl),
                }
              end
            end
          end
          num.xpath('w:lvlOverride').each do |over|
            indent_level = over['w:ilvl'].to_i
            if start_over = over.at_xpath('w:startOverride')
              @numbering_desc[num_id][indent_level][:start] = start_over['w:val'].to_i
            elsif lvl = over.at_xpath('w:lvl')
              @numbering_desc[num_id][indent_level] = {
                :start  => lvl.at_xpath('w:start')['w:val'].to_i,
                :numFmt => lvl.at_xpath('w:numFmt')['w:val'],
                :format => lvl.at_xpath('w:lvlText')['w:val'],
                :isLgl  => get_bool(lvl.at_xpath('w:isLgl')),
                :style  => node_style(lvl),
              }
            end
          end
        end
      end
      @doc.xpath('//w:document//w:body').children.map do |node|
        case node.node_name
        when 'text'
          @result.blocks << parse_paragraph(node)
        when 'tbl'
          @result.blocks << parse_table(node)
        when 'p'
          @result.blocks << parse_paragraph(node)
        else
          # skip
        end
      end
      @result
    end
    
   private
    def character_encode(text)
      text.force_encoding('utf-8')
      # NOTE
      # :named only for escape at Builder
      text = @coder.encode(text, :named)
      text
    end
    def parse_image(r)
      id = nil
      img = Image.new
      additional_namespaces = {
        'xmlns:a'   => 'http://schemas.openxmlformats.org/drawingml/2006/main',
        'xmlns:pic' => 'http://schemas.openxmlformats.org/drawingml/2006/picture'
      }
      ns = r.namespaces.merge additional_namespaces
      [
        { # old type shape
          :attr => 'id',
          :path => './/w:pict//v:shape//v:imagedata',
        },
        { # in anchor
          :attr => 'r:embed',
          :path => './/w:drawing//wp:anchor',
        },
        { # inline
          :attr => 'r:embed',
          :path => './/w:drawing//wp:inline',
        },
      ].each do |element|
        if image = r.at_xpath(element[:path], ns)
          if wrap = image.at_xpath('wp:wrapTopAndBottom', ns)
            img.wrap = 'block'
          end
          if size = image.at_xpath('wp:extent', ns)
            img.width = size['cx'].to_i / 9525
            img.height = size['cy'].to_i / 9525
          end
          if blip = image.at_xpath('a:graphic//a:graphicData//pic:pic//pic:blipFill//a:blip', ns)
            image = blip
          end
          id = image[element[:attr]]              
          if id
            if file = @rel_files.select{ |file| file[:id] == id }.first
              target = file[:target]
              source = source_path(target)
              data = file[:stream].read
              @images << {
                :origin => target,
                :source => source,
                :data => data,
              }
              img.src = @image_url + source
              img.img_hash = data.hash
            end
          else
            img.img_hash = image.to_s.hash
          end
          break
        end
      end
      img
    end
    def source_path(target)
      source = @image_path + '/'
      if defined? Magick::Image and
         ext = File.extname(target).match(/\.wmf$/).to_a[0]
        source << File.basename(target, ext) + '.png'
      else
        source << File.basename(target)
      end
    end
    def parse_paragraph(node)
      paragraph = Paragraph.new
      paragraph_runs = []
      paragraph_style = Style.new
      if ppr = node.at_xpath('w:pPr')
        ppr.children.each do |child|
          if child.name == 'jc'
            paragraph.align = child['w:val']
            if paragraph.align == 'both'
              paragraph.align = 'justify'
            end
          end
          if child.name == 'pStyle'
            paragraph_style = @styles[child['w:val']]
          end
        end
      end

      node_style = node_style(node)
      style = @default_style.dup
      style.apply(paragraph_style)
      style.apply(node_style)

      num_id = style.numid
      indent_level = style.ilvl || 0
      unless num_id.nil?
        if @numbering_desc[num_id] && num_desc = @numbering_desc[num_id][indent_level]
          format = num_desc[:format]
          is_legal = num_desc[:isLgl]
          num_style = @default_style.dup
          num_style.apply(paragraph_style)
          # It seems that text size from pPr.rPr applies to numbering in some cases...
          if sz = node.at_xpath('w:pPr//w:rPr//w:sz')
            num_style.sz = sz['w:val'].to_i
          end
          num_style.apply(num_desc[:style])
          num_style.apply(node_style)

          for ilvl in 0..indent_level
            if num_desc = @numbering_desc[num_id][ilvl]
              num = num_desc[:start] + @numbering_count[num_id][ilvl] - (ilvl < indent_level ? 1 : 0)
              replace = '%' + (ilvl+1).to_s
              next if !format.include?(replace)
              str = format_number(num, (is_legal and ilvl < indent_level) ? 'decimal' : num_desc[:numFmt])
            end
            format = format.sub(replace, str)
          end              
          @numbering_count[num_id][indent_level] += 1
          # reset higher counts
          @numbering_count[num_id].each_key do |level|
            if level > indent_level
              @numbering_count[num_id][level] = 0
            end
          end
          unless format == ''
            paragraph_runs << parse_text(format + ' ', num_style)
          end
        end
      end
      
      node.children.each do |child|
        has_image = false
        runs = []
        child.xpath('.//w:pict|.//w:drawing|.//w:r').each do |run|
          if run.name == 'pict' || run.name == 'drawing'
            has_image = true
          elsif run.name == 'r'
            runs << run
          end
        end
        if has_image
          paragraph_runs << parse_image(child)
          next
        end
        if child.name == 'r'
          runs << child
        end
        runs.each do |r|
          r_style = style.dup
          r_style.apply(node_style(r))
          text = ''
          r.children.each do |t|
            if t.name == 'br'
              text += "\n"
            elsif t.name == 'tab'
              text += "        "
            elsif t.name == 't'
              text += t.text
            elsif t.name == 'sym'
              text += t.text
              val = t['w:char'].to_i(16)
              if val >= 0xf000
                val -= 0xf000
              end
              chr_style = r_style.dup()
              if t['w:font']
                chr_style.font = t['w:font']
              end
              paragraph_runs << parse_text(text, r_style)
              paragraph_runs << parse_text('&#x' + val.to_s(16) + ';', chr_style, true)
              text = ''
            elsif t.name == 'footnoteReference' &&
                  (t['w:customMarkFollows'].nil? || t['w:customMarkFollows'] == 'false')
              text += format_number(@cur_footnote, @footnote_fmt)
              @cur_footnote += 1
            elsif t.name == 'endnoteReference' &&
                  (t['w:customMarkFollows'].nil? || t['w:customMarkFollows'] == 'false')
              text += format_number(@cur_endnote, @endnote_fmt)
              @cur_endnote += 1
            end
          end
          unless text.empty?
            paragraph_runs << parse_text(text, r_style)
          end
        end
      end
      
      paragraph.groups = RunGroup.split_runs(RunGroup.merge_runs(paragraph_runs))
      paragraph
    end
    def parse_table(node)
      table = Table.new
      
      vmerge_type = {}
      # first, compute rowspans
      node.xpath('w:tr').each_with_index do |tr, row|
        vmerge_type[row] = {}
        col = 0
        tr.xpath('w:tc').each do |tc|
          tc.xpath('w:tcPr').each do |tcpr|
            cells = 1
            if span = tcpr.at_xpath('w:gridSpan')
              cells = span['w:val'].to_i
            end
            if merge = tcpr.at_xpath('w:vMerge')
              if merge['w:val'].nil?
                vmerge_type[row][col] = 1;
              else
                vmerge_type[row][col] = 2
              end
            else
              vmerge_type[row][col] = 0
            end
            col += cells
          end
        end
      end
      
      node.xpath('w:tr').each_with_index do |tr, row|
        row_height = nil
        if trh = tr.at_xpath('w:trPr//w:trHeight')
          row_height = trh['w:val'].to_i * 96 / 1440
        end
        table_row = Row.new
        table.rows << table_row
        col = 0
        tr.xpath('w:tc').each do |tc|
          cell = Cell.new
          cell.parent = table
          cell.height = row_height
          columns = 1
          if tcpr = tc.at_xpath('w:tcPr')
            if span = tcpr.at_xpath('w:gridSpan')
              columns = cell.colspan = span['w:val'].to_i
            end
            if w = tcpr.at_xpath('w:tcW')
              cell.width = w['w:w'].to_i * 96 / 1440
            end
            if vmerge_type[row][col] == 2
              nrow = row + 1
              while !vmerge_type[nrow].nil? and vmerge_type[nrow][col] == 1
                nrow += 1
              end
             cell.rowspan = nrow - row
            end
            if align = tcpr.at_xpath('w:vAlign')
              cell.valign = align['w:val']
            end
          end
          tc.children.each do |child|
            case child.name
            when 'text'
              cell.blocks << parse_paragraph(child)
            when 'tbl'
              cell.blocks << parse_table(child)
            when 'p'
              cell.blocks << parse_paragraph(child)
            else
              # skip
            end
          end
          if vmerge_type[row][col] != 1
            table_row.cells << cell
          end
          col += columns
        end
      end
      table
    end
    def parse_text(text, style, raw = false)
      unless raw
        text = character_encode(text)
      end
      text_style = style.dup
      text_style.ilvl = text_style.numid = nil
      Run.new text, text_style
    end
  end
end
