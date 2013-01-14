class APN::App < APN::Base

  has_many :groups, :class_name => 'APN::Group', :dependent => :destroy
  has_many :devices, :class_name => 'APN::Device', :dependent => :destroy
  has_many :notifications, :through => :devices, :dependent => :destroy
  has_many :unsent_notifications, :through => :devices
  has_many :group_notifications, :through => :groups
  has_many :unsent_group_notifications, :through => :groups

  def cert
    (RAILS_ENV == 'production' ? apn_prod_cert : apn_dev_cert)
  end

  # Opens a connection to the Apple APN server and attempts to batch deliver
  # an Array of group notifications.
  #
  #
  # As each APN::GroupNotification is sent the <tt>sent_at</tt> column will be timestamped,
  # so as to not be sent again.
  #
  def send_notifications
    if self.cert.nil?
      raise APN::Errors::MissingCertificateError.new
      return
    end
    APN::App.send_notifications_for_cert(self.cert, self.id)
  end

  def self.send_notifications
    apps = APN::App.all
    apps.each do |app|
      app.send_notifications
    end
    if !configatron.apn.cert.blank?
      global_cert = File.read(configatron.apn.cert)
      send_notifications_for_cert(global_cert, nil)
    end
  end

  def self.log_bad_message(msg)
    @logger ||= Logger.new(Rails.root.join("log", "apn_errors.log").to_s)
    @logger.fatal(msg)
  end

  def self.send_notifications_for_cert(the_cert, app_id)
    # unless self.unsent_notifications.nil? || self.unsent_notifications.empty?
      begin
        APN::Notification.delete_all("sent_at IS NOT NULL")

        APN::Connection.open_for_delivery({:cert => the_cert}) do |conn, sock|
          APN::Notification.find_each(:conditions => {:sent_at => nil}) do |n|
            begin
              conn.write(n.message_for_sending)

            rescue APN::Errors::ExceededMessageSizeError => e
              log_bad_message(e.message)

              # The message for sending could be a malformed message that includes
              # bad UTF8 characters. Instead of raising the error we caught, we
              # make a new error so that services that serialize the error
              # message do not blow up when deserializing (e.g., sidekiq).
              raise "APN MessageSizeError -> Check log/apn_errors.log for errors"
            ensure
              # Even if the message is bad, we save the state as sent so we don't
              # have to deal with it anymore. These messages aren't *critical* for
              # the site to run, so losing bad messages is fine.
              n.sent_at = Time.now
              n.save
            end
          end
        end

      rescue Exception => e
        log_connection_exception(e)
      end
    # end
  end

  def send_group_notifications
    if self.cert.nil?
      raise APN::Errors::MissingCertificateError.new
      return
    end
    unless self.unsent_group_notifications.nil? || self.unsent_group_notifications.empty?
      APN::Connection.open_for_delivery({:cert => self.cert}) do |conn, sock|
        unsent_group_notifications.each do |gnoty|
          gnoty.devices.find_each do |device|
            conn.write(gnoty.message_for_sending(device))
          end
          gnoty.sent_at = Time.now
          gnoty.save
        end
      end
    end
  end

  def send_group_notification(gnoty)
    if self.cert.nil?
      raise APN::Errors::MissingCertificateError.new
      return
    end
    unless gnoty.nil?
      APN::Connection.open_for_delivery({:cert => self.cert}) do |conn, sock|
        gnoty.devices.find_each do |device|
          conn.write(gnoty.message_for_sending(device))
        end
        gnoty.sent_at = Time.now
        gnoty.save
      end
    end
  end

  def self.send_group_notifications
    apps = APN::App.all
    apps.each do |app|
      app.send_group_notifications
    end
  end

  # Retrieves a list of APN::Device instnces from Apple using
  # the <tt>devices</tt> method. It then checks to see if the
  # <tt>last_registered_at</tt> date of each APN::Device is
  # before the date that Apple says the device is no longer
  # accepting notifications then the device is deleted. Otherwise
  # it is assumed that the application has been re-installed
  # and is available for notifications.
  #
  # This can be run from the following Rake task:
  #   $ rake apn:feedback:process
  def process_devices
    if self.cert.nil?
      raise APN::Errors::MissingCertificateError.new
      return
    end
    APN::App.process_devices_for_cert(self.cert)
  end # process_devices

  def self.process_devices
    apps = APN::App.all
    apps.each do |app|
      app.process_devices
    end
    if !configatron.apn.cert.blank?
      global_cert = File.read(configatron.apn.cert)
      APN::App.process_devices_for_cert(global_cert)
    end
  end

  def self.process_devices_for_cert(the_cert)
    puts "in APN::App.process_devices_for_cert"
    APN::Feedback.devices(the_cert).each do |device|
      if device.last_registered_at < device.feedback_at
        puts "device #{device.id} -> #{device.last_registered_at} < #{device.feedback_at}"
        device.destroy
      else
        puts "device #{device.id} -> #{device.last_registered_at} not < #{device.feedback_at}"
      end
    end
  end

  protected

  def self.log_connection_exception(ex)
    STDERR.puts ex.message
    raise ex
  end

end

