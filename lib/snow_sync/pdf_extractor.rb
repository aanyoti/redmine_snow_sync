require 'shellwords'
require 'open3'

module SnowSync
  class PdfExtractor
    def self.extract(diskfile)
      new(diskfile).extract
    end

    def initialize(diskfile)
      @diskfile = diskfile
    end

    def extract
      text, status = Open3.capture2('pdftotext', @diskfile, '-')
      return {} unless status.success? && text.present?

      {
        customer_name:  extract_customer_name(text),
        account_number: extract_pattern(text, /Account Number:\s*(.+)/),
        prepared_by:    extract_pattern(text, /Prepared by:\s*(.+)/),
        currency:       detect_currency(text),
        nrr:            extract_subtotal(text, 0),
        mrr:            extract_subtotal(text, 1)
      }.compact
    end

    private

    def extract_customer_name(text)
      match = text.match(/LIQUID INTELLIGENT TECHNOLOGIES QUOTATION\s*\n+\s*(.+)/)
      match ? match[1].strip : nil
    end

    def extract_pattern(text, pattern)
      match = text.match(pattern)
      match ? match[1].strip : nil
    end

    def detect_currency(text)
      text.match(/charge\s*[\r\n]+\s*\(([A-Z]{3})\)/i)&.[](1)&.upcase ||
        text.match(/charge\s+\(([A-Z]{3})\)/i)&.[](1)&.upcase ||
        'ZMW'
    end

    def extract_subtotal(text, index)
      after = text.split(/Subtotal \(excl\. VAT\)/, 2).last
      return nil if after.blank?

      numbers = after.scan(/[\d,]+\.\d{2}/)
      numbers[index]
    end
  end
end
