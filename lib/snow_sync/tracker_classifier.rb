module SnowSync
  class TrackerClassifier
    KEYWORD_MAP = {
      'VoIP'           => ['SIP Trunk', 'SIP Channel', 'SIP Channels', 'Number Block',
                           'VoIP', 'IVR', 'Conference Facilities', 'Cloud PBX',
                           'Hosted PBX', 'UCaaS'],
      'M365'           => ['Microsoft 365', 'M365', 'Office 365', 'MS365',
                           'Office365', 'MS Office', 'Microsoft Office',
                           'Enterprise Mobility', 'Microsoft Products',
                           'Teams', 'SharePoint', 'Intune', 'Dynamics', 'Exchange'],
      'Cloud - Azure'  => ['Azure'],
      'Cloud - AWS'    => ['AWS', 'Amazon Web Services'],
      'Cloud - Google' => ['Google Workspace', 'Google Cloud', 'GCP', 'Google Meet'],
      'Cybersecurity'  => ['Cybersecurity', 'Cyber Security', 'Firewall', 'SOC',
                           'SIEM', 'EDR', 'Endpoint Protection', 'FortiGate', 'Sophos'],
      'Cloud PBX'      => ['Cloud PBX', 'Hosted PBX', 'UCaaS'],
      'Licensing'      => ['Licensing', 'License', 'Licence'],
    }.freeze

    def self.classify(text)
      return nil if text.blank?
      normalized = text.downcase
      KEYWORD_MAP.each do |service_type, keywords|
        keywords.each do |kw|
          return service_type if normalized.include?(kw.downcase)
        end
      end
      nil
    end

    def self.c2_tracker
      @c2_tracker ||= Tracker.find_by(name: 'C2')
    end

    def self.classify_issue(subject, description = '')
      text = [subject, description].join(' ')
      service_type = classify(text)
      return nil unless service_type
      { tracker: c2_tracker, service_type: service_type }
    end
  end
end
