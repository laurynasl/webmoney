require File.dirname(__FILE__) +'/wmsigner'
require 'time'
require 'net/http'
require 'net/https'
require 'rubygems'
require 'iconv'
require 'builder'
require 'hpricot'

class Object
  def blank?
    respond_to?(:empty?) ? empty? : !self
  end
end

# Main class for Webmoney lib. Instance contain info
# for Webmoney interfaces requests (wmid, key, etc). 
# Implement base requests to Webmoney.
class Webmoney

  # Error classes
  class WebmoneyError < StandardError; end
  class RequestError < WebmoneyError;  end
  class ResultError < WebmoneyError;  end
  class IncorrectWmidError < WebmoneyError; end
  class CaCertificateError < WebmoneyError; end
  
  require File.dirname(__FILE__) + '/../lib/wmid'
  require File.dirname(__FILE__) + '/../lib/passport'
  require File.dirname(__FILE__) + '/../lib/messenger'
  
  attr_reader :wmid, :error, :errormsg, :last_request, :messenger
  
  # Required options:
  # :wmid (WMID)
  # :password (on Classic key or Light X509 certtificate & key)
  # :key (Base64 string for Classic key) 
  # OR TODO!
  # :key (OpenSSL::PKey::RSA or OpenSSL::PKey::DSA object) AND
  # :cert OpenSSL::X509::Certificate object
  # Optional:
  # :ca_cert (path of a CA certification file in PEM format)
  def initialize(opt = {})
    @wmid = Wmid.new(opt[:wmid])
    
    # classic or light
    case opt[:key]
      when String
        @signer = Signer.new(@wmid, opt[:password], opt[:key])
      when OpenSSL::PKey::RSA, OpenSSL::PKey::DSA
        @key = opt[:key]
        @cert = opt[:cert]
        @password = opt[:password]
    end
    
    # ca_cert or default
    @ca_cert = 
      if opt[:ca_cert].nil?
         File.dirname(__FILE__) + '/../lib/WebMoneyCA.crt'
      else
        opt[:ca_cert]
      end

    w3s = 'https://w3s.wmtransfer.com/asp/'
    
    @interfaces = {
      'create_invoice'  => URI.parse( w3s + 'XMLInvoice.asp' ), # x1
      'create_transaction'  => URI.parse( w3s + 'XMLTrans.asp' ), # x2
      'operation_history'  => URI.parse( w3s + 'XMLOperations.asp' ), # x3
      'outgoing_invoices'  => URI.parse( w3s + 'XMLOutInvoices.asp' ), # x4
      'finish_protect'  => URI.parse( w3s + 'XMLFinishProtect.asp' ), # x5
      'send_message'  => URI.parse( w3s + 'XMLSendMsg.asp'), # x6
      'check_sign'  => URI.parse( w3s + 'XMLClassicAuth.asp'), # x7
      'find_wm'  => URI.parse( w3s + 'XMLFindWMPurse.asp'), # x8
      'balance'  => URI.parse( w3s + 'XMLPurses.asp'), # x9
      'incoming_invoices' => URI.parse( w3s + 'XMLInInvoices.asp'), # x10
      'get_passport' => URI.parse( 'https://passport.webmoney.ru/asp/XMLGetWMPassport.asp'), # x11
      'reject_protection' => URI.parse( w3s + 'XMLRejectProtect.asp'), # x13
      'transaction_moneyback' => URI.parse( w3s + 'XMLTransMoneyback.asp'), # 14
      'i_trust'  => URI.parse( w3s + 'XMLTrustList.asp'), # x15
      'trust_me'  => URI.parse( w3s + 'XMLTrustList2.asp'), # x15
      'trust_save'  => URI.parse( w3s + 'XMLTrustSave2.asp'), # x15
      'create_purse'  => URI.parse( w3s + 'XMLCreatePurse.asp'), # x16
      'bussines_level'  => URI.parse( 'https://stats.wmtransfer.com/levels/XMLWMIDLevel.aspx')
    }
    # Iconv.new(to, from)
    @ic_in = Iconv.new('UTF-8', 'CP1251')
    @ic_out = Iconv.new('CP1251', 'UTF-8')
  end
  
  def classic?
    ! @signer.nil?
  end
  
  # Send message through Queue and Thread
  # Params - :wmid, :subj, :text
  def send_message(params)
    @messenger = Messenger.new(self) if @messenger.nil?
    @messenger.push(params)
  end
  
  # ================================================
  # Main interface function
  # ================================================
  def request(iface, opt ={})
    reqn = reqn()
    raise ArgumentError unless opt.kind_of?(Hash)
    opt[:wmid] = @wmid if opt[:wmid].nil?
    x = Builder::XmlMarkup.new(:indent => 1)
    x.instruct!(:xml, :version=>"1.0", :encoding=>"windows-1251")
    unless [:get_passport, :bussines_level].include?(iface)
      x.tag!('w3s.request') do
        x.wmid @wmid
        case iface
          when :check_sign then
            plan_out = @ic_out.iconv(opt[:plan])
            x.testsign do 
              x.wmid opt[:wmid]
              x.plan { x.cdata! plan_out } 
              x.sign opt[:sign]
            end
            plan = @wmid + opt[:wmid] + plan_out + opt[:sign]
          when :send_message
            x.reqn reqn
            msgsubj = @ic_out.iconv(opt[:subj])
            msgtext = @ic_out.iconv(opt[:text])
            x.message do
              x.receiverwmid opt[:wmid]
              x.msgsubj { x.cdata! msgsubj }
              x.msgtext { x.cdata! msgtext }
            end
            plan = opt[:wmid] + reqn + msgtext + msgsubj
        end
        x.sign sign(plan) if classic?
      end
    else
      case iface
        when :bussines_level
          x.tag!('WMIDLevel.request') do
            x.signerwmid @wmid
            x.wmid opt[:wmid]
          end
        when :get_passport
          x.request do
            x.wmid @wmid
            x.passportwmid opt[:wmid]
            x.params { x.dict 0; x.info 1; x.mode 0 }
            x.sign sign(@wmid + opt[:wmid]) if classic?
          end
      end
    end
    
    # Request do!
    res = https_request(iface, x.target!)
    
    # Parse response
    parse_retval(res)
    doc = Hpricot.XML(res)
    case iface
      when :check_sign
        return doc.at('//testsign/res').inner_html == 'yes' ? true : false
      when :get_passport
        return Passport.new(doc)
      when :bussines_level
        return doc.at('//level').inner_html.to_i
      when :send_message
        time = doc.at('//message/datecrt').inner_html
        m = time.match(/(\d{4})(\d{2})(\d{2}) (\d{2}):(\d{2}):(\d{2})/)
        time = Time.mktime(*m[1..6])
        return {:id => doc.at('//message')['id'], :date => time}
    end
  end
  
  protected

  # Signing string by instance wmid's
  # Return signed string
  def sign(str)
    @signer.sign(str) unless str.blank?
  end
    
  # Make HTTPS request, return result body if 200 OK
  def https_request(iface, xml)
    url = case iface
      when Symbol
        @interfaces[iface.to_s]
      when String
        URI.parse(iface)
    end
    http = Net::HTTP.new(url.host, url.port)
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    if File.file? @ca_cert
      http.ca_file = @ca_cert
    else
      raise CaCertificateError
    end
    http.use_ssl = true
    @last_request = xml
    result = http.post( url.path, xml, "Content-Type" => "text/xml" )
    case result
      when Net::HTTPSuccess
        # replace root tag for Hpricot
        res = result.body.gsub(/(w3s\.response|WMIDLevel\.response)/,'w3s_response')
        return @ic_in.iconv(res)
      else
        @error = result.code
        @errormsg = result.body if result.class.body_permitted?()
        raise RequestError
    end
  end

  def parse_retval(response_xml)
    doc = Hpricot.XML(response_xml)
    retval_element = doc.at('//retval')
    # Workaround for passport interface
    unless retval_element.nil?
      retval = retval_element.inner_html.to_i
      retdesc = doc.at('//retdesc').inner_html unless doc.at('//retdesc').nil?
    else
      retval = doc.at('//response')['retval'].to_i
      retdesc = doc.at('//response')['retdesc']
    end
    unless retval == 0
        @error = retval
        @errormsg = retdesc
        raise ResultError
    end
  end

  # Create unique Request Number based on time
  # Return 16 digits string
  def reqn
    t = Time.now
    t.strftime('%Y%m%d%H%M%S') + t.to_f.to_s.match(/\.(\d\d)/)[1]
  end
    
end
