require 'puppet/application'
require 'puppet/ssl/oids'

class Puppet::Application::Ssl < Puppet::Application
  def summary
    _("Manage SSL keys and certificates for puppet SSL clients")
  end

  def help
    <<-HELP
puppet-ssl(8) -- #{summary}
========

SYNOPSIS
--------
Manage SSL keys and certificates for an SSL clients needed
to communicate with a puppet infrastructure.

USAGE
-----
puppet ssl <action> [--certname <NAME>] [--localca]

ACTIONS
-------

* submit_request:
  Generate a certificate signing request (CSR) and submit it to the CA. If a private and
  public key pair already exist, they will be used to generate the CSR. Otherwise a new
  key pair will be generated. If a CSR has already been submitted with the given `certname`,
  then the operation will fail.

* download_cert:
  Download a certificate for this host. If the current private key matches the downloaded
  certificate, then the certificate will be saved and used for subsequent requests. If
  there is already an existing certificate, it will be overwritten.

* verify:
  Verify the private key and certificate are present and match, verify the certificate is
  issued by a trusted CA, and check revocation status.

* clean:
  Remove the private key and certificate related files for this host. If `--localca` is
  specified, then also remove this host's local copy of the CA certificate(s) and CRL bundle.
HELP
  end

  option('--certname NAME') do |arg|
    options[:certname] = arg
  end

  option('--localca')

  def main
    if command_line.args.empty?
      raise Puppet::Error, _("An action must be specified.\n%{help}") % { help: help }
    end

    Puppet.settings.use(:main, :agent)
    host = Puppet::SSL::Host.new(options[:certname])

    action = command_line.args.first
    case action
    when 'submit_request'
      submit_request(host)
      download_cert(host)
    when 'download_cert'
      download_cert(host)
    when 'verify'
      verify(host)
    when 'clean'
      clean(host)
    else
      raise Puppet::Error, _("Unknown action '%{action}'") % { action: action }
    end
  end

  def submit_request(host)
    host.ensure_ca_certificate

    host.submit_request
    puts _("Submitted certificate request for '%{name}' to https://%{server}:%{port}") % {
      name: host.name, server: Puppet[:ca_server], port: Puppet[:ca_port]
    }
  rescue => e
    raise Puppet::Error, _("Failed to submit certificate request: %{message}") % { message: e.message }
  end

  def download_cert(host)
    host.ensure_ca_certificate

    puts _("Downloading certificate '%{name}' from https://%{server}:%{port}") % {
      name: host.name, server: Puppet[:ca_server], port: Puppet[:ca_port]
    }
    if cert = host.download_host_certificate
      puts _("Downloaded certificate '%{name}' with fingerprint %{fingerprint}") % {
        name: host.name, fingerprint: cert.fingerprint
      }
    else
      puts _("No certificate for '%{name}' on CA") % { name: host.name }
    end
  rescue => e
    raise Puppet::Error, _("Failed to download certificate: %{message}") % { message: e.message }
  end

  def verify(host)
    host.ensure_ca_certificate

    key = host.key
    raise _("The host's private key is missing") unless key

    cert = host.check_for_certificate_on_disk(host.name)
    raise _("The host's certificate is missing") unless cert

    if cert.content.public_key.to_pem != key.content.public_key.to_pem
      raise _("The host's key does not match the certificate")
    end

    store = host.ssl_store
    unless store.verify(cert.content)
      raise _("Failed to verify certificate '%{name}': %{message} (%{error})") % {
        name: host.name, message: store.error_string, error: store.error
      }
    end

    puts _("Verified certificate '%{name}'") % {
      name: host.name
    }
    # store.chain.reverse.each_with_index do |issuer, i|
    #   indent = "  " * (i+1)
    #   puts "#{indent}#{issuer.subject.to_s}"
    # end
  rescue => e
    raise Puppet::Error, _("Verify failed: %{message}") % { message: e.message }
  end

  def clean(host)
    # resolve the `ca_server` setting using `agent` run mode
    ca_server = Puppet.settings.values(Puppet[:environment].to_sym, :agent).interpolate(:ca_server)
    if Puppet[:certname] == ca_server
      # make sure cert has been removed from the CA
      cert = host.download_certificate_from_ca(Puppet[:certname])
      if cert
        raise Puppet::Error, _(<<END) % { certname: Puppet[:certname] }
The certificate %{certname} must be cleaned from the CA first. To fix this,
run the following commands on the CA:
  puppetserver ca clean --certname %{certname}
  puppet ssl clean
END
      end
    end

    settings = {
      hostprivkey: 'private key',
      hostpubkey: 'public key',
      hostcsr: 'certificate request',
      hostcert: 'certificate',
      passfile: 'private key password file'
    }
    settings.merge!(localcacert: 'local CA certificate', hostcrl: 'local CRL') if options[:localca]
    settings.each_pair do |setting, label|
      path = Puppet[setting]
      if Puppet::FileSystem.exist?(path)
        Puppet::FileSystem.unlink(path)
        puts _("Removed %{label} %{path}") % { label: label, path: path }
      end
    end
  end
end
