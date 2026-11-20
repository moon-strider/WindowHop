#!/usr/bin/ruby
require 'openssl'
require 'open3'
require 'securerandom'
require 'fileutils'

Dir.chdir(__dir__)
certificate_path = File.join(__dir__, 'Resources', 'SigningCertificate.cer')
keychain = File.join(Dir.home, 'Library', 'Keychains', 'login.keychain-db')
name = 'WindowHop Local Signing'
identities, identity_status = Open3.capture2e('/usr/bin/security', 'find-identity', '-p', 'codesigning', keychain)
abort 'Не удалось прочитать сертификаты подписи в связке ключей.' unless identity_status.success?

if File.exist?(certificate_path)
  certificate = OpenSSL::X509::Certificate.new(File.binread(certificate_path))
  fingerprint = OpenSSL::Digest::SHA1.hexdigest(certificate.to_der).upcase
  abort 'Постоянный ключ WindowHop отсутствует в Keychain. Сертификат автоматически не заменяется.' unless identities.include?(fingerprint)
  puts 'Постоянный сертификат WindowHop уже настроен.'
  exit
end

abort 'Сертификат WindowHop уже есть в Keychain. Восстановите Resources/SigningCertificate.cer вместо создания другого ключа.' if identities.include?(name)

key = OpenSSL::PKey::RSA.new(3072)
certificate = OpenSSL::X509::Certificate.new
certificate.version = 2
certificate.serial = SecureRandom.random_number(2**127) + 1
certificate.subject = OpenSSL::X509::Name.new([['CN', name]])
certificate.issuer = certificate.subject
certificate.public_key = key.public_key
certificate.not_before = Time.now - 300
certificate.not_after = Time.now + 10 * 365 * 24 * 60 * 60
extensions = OpenSSL::X509::ExtensionFactory.new
extensions.subject_certificate = certificate
extensions.issuer_certificate = certificate
certificate.add_extension(extensions.create_extension('basicConstraints', 'CA:FALSE', true))
certificate.add_extension(extensions.create_extension('keyUsage', 'digitalSignature', true))
certificate.add_extension(extensions.create_extension('extendedKeyUsage', 'codeSigning', true))
certificate.add_extension(extensions.create_extension('subjectKeyIdentifier', 'hash'))
certificate.sign(key, OpenSSL::Digest::SHA256.new)

password = SecureRandom.hex(32)
archive = OpenSSL::PKCS12.create(password, name, key, certificate)
FileUtils.mkdir_p('tmp')
archive_path = File.join(__dir__, 'tmp', "signing-#{SecureRandom.hex(8)}.p12")
File.open(archive_path, File::WRONLY | File::CREAT | File::EXCL, 0600) { |file| file.write(archive.to_der) }
begin
  output, status = Open3.capture2e('/usr/bin/security', 'import', archive_path, '-k', keychain,
    '-f', 'pkcs12', '-P', password, '-x', '-T', '/usr/bin/codesign')
  abort "Не удалось импортировать ключ: #{output}" unless status.success?
  File.binwrite(certificate_path, certificate.to_der)
  puts 'Сертификат создан. Неэкспортируемый закрытый ключ сохранён в login Keychain; доступ разрешён codesign.'
ensure
  script = "on run arguments\nset targetItem to (POSIX file (item 1 of arguments)) as alias\ntell application \"Finder\" to delete targetItem\nend run"
  output, status = Open3.capture2e('/usr/bin/osascript', '-e', script, archive_path)
  warn "Не удалось перенести временный зашифрованный контейнер в Корзину: #{output}" unless status.success?
end
