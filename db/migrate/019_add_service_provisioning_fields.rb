class AddServiceProvisioningFields < ActiveRecord::Migration[7.2]
  SERVICE_PROVISIONING_CFS = [
    { name: 'A-End Termination POP',  field_format: 'string' },
    { name: 'A-End Switch/Router',     field_format: 'string' },
    { name: 'A-End Termination Port',  field_format: 'string' },
    { name: 'B-End Termination POP',  field_format: 'string' },
    { name: 'B-End Switch/Router',     field_format: 'string' },
    { name: 'B-End Termination Port',  field_format: 'string' },
    { name: 'VLAN/IP',                field_format: 'string' },
    { name: 'Bandwidth Capacity',     field_format: 'string' },
  ].freeze

  def up
    trackers = Tracker.where(id: [14, 18])

    SERVICE_PROVISIONING_CFS.each do |attrs|
      next if IssueCustomField.find_by(name: attrs[:name])

      cf = IssueCustomField.create!(
        name:         attrs[:name],
        field_format: attrs[:field_format],
        is_required:  false,
        is_for_all:   true,
        searchable:   true,
        editable:     true,
        visible:      true
      )
      cf.trackers = trackers
      cf.save!
    end
  end

  def down
    SERVICE_PROVISIONING_CFS.each do |attrs|
      IssueCustomField.find_by(name: attrs[:name])&.destroy
    end
  end
end
