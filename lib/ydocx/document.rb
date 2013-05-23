#!/usr/bin/env ruby
# encoding: utf-8

require 'pathname'
require 'zip/zip'
require 'rmagick'
require 'ydocx/parser'
require 'ydocx/builder'

module YDocx
  class Document
    attr_reader :builder, :contents, :images, :parser, :path
    def self.open(file)
      self.new(file)
    end
    def initialize(file)
      @parser = nil
      @builder = nil
      @contents = nil
      @images = []
      @path = Pathname.new('.')
      @files = nil
      @zip = nil
      init
      read(file)
    end
    def init
    end
    def output_directory
      @files ||= @path.dirname.join(@path.basename('.docx').to_s + '_files')
    end
    def output_file(ext)
      @path.sub_ext(".#{ext.to_s}")
    end
    def to_html(output=false)
      html = ''
      files = output_directory
      @builder = Builder.new(@contents) do |builder|
        builder.title = @path.basename
        builder.files = files.relative_path_from(files.dirname)
        builder.style = true
        html = builder.build_html
      end
      if output
        create_files if has_image?
        html_file = output_file(:html)
        File.open(html_file, 'w:utf-8') do |f|
          f.puts html
        end
      end
      html
    end
    def to_xml(output=false)
      xml = ''
      Builder.new(@contents) do |builder|
        xml = builder.build_xml
      end
      if output
        xml_file = output_file(:xml)
        mkdir xml_file.parent
        File.open(xml_file, 'w:utf-8') do |f|
          f.puts xml
        end
      end
      xml
    end
    private
    def create_files
      files_dir = output_directory
      mkdir Pathname.new(files_dir) unless files_dir.exist?
      @images.each do |image|
        origin_path = Pathname.new image[:origin] # media/filename.ext
        source_path = Pathname.new image[:source] # images/filename.ext
        image_dir = files_dir.join source_path.dirname
        FileUtils.mkdir image_dir unless image_dir.exist?
        organize_image(origin_path, source_path, image[:data])
      end
    end
    def organize_image(origin_path, source_path, data)
      if source_path.extname != origin_path.extname # convert
        output_file = output_directory.join(source_path)
        output_file.open('wb') do |f|
          f.puts data
        end
        if defined? Magick::Image
          image = Magick::Image.read(output_file).first
          image.format = source_path.extname[1..-1].upcase
          output_directory.join(source_path).open('wb') do |f|
            f.puts image.to_blob
          end
        end
      else
        output_directory.join(source_path).open('wb') do |f|
          f.puts data
        end
      end
    end
    def has_image?
      !@images.empty?
    end
    def read(file)
      @path = Pathname.new file
      @zip = Zip::ZipFile.open(@path.realpath)
      doc = @zip.find_entry('word/document.xml').get_input_stream
      rel = @zip.find_entry('word/_rels/document.xml.rels').get_input_stream
      rel_xml = Nokogiri::XML.parse(rel)
      rel_files = []
      rel_xml.xpath('/').children.each do |relat|
        relat.children.each do |r|
          if file = @zip.find_entry('word/' + r['Target'])
            rel_files << {
              :id => r['Id'],
              :type => r['Type'],
              :target => r['Target'],
              :stream => file.get_input_stream
            }
          end
        end
      end
      rel = @zip.find_entry('word/_rels/document.xml.rels').get_input_stream
      @parser = Parser.new(doc, rel, rel_files) do |parser|
        @contents = parser.parse
        @images = parser.images
      end
      @zip.close
    end
    def mkdir(path)
      return if path.exist?
      parent = path.parent
      mkdir(parent)
      FileUtils.mkdir(path)
    end
  end
end
