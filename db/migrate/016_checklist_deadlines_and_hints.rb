class ChecklistDeadlinesAndHints < ActiveRecord::Migration[7.2]
  # [sort_order, deadline_days, updated_title]
  # Titles are enhanced with a guidance hint in parentheses where relevant.
  UPDATES = {
    'Site Survey Checklist' => [
      [0, 1,  'Site access arranged and confirmed with customer (include contact name and agreed time)'],
      [1, 2,  'Existing infrastructure and cabling documented (photos or sketches of existing cabling)'],
      [2, 2,  'Fibre routing path identified and measured (record total metres in Fiber Length field)'],
      [3, 2,  'Power supply verified at termination / comms room (confirm socket availability and voltage)'],
      [4, 2,  'Customer rack space and comms room confirmed (note rack units available and room access hours)'],
      [5, 2,  'Hazards and obstructions noted (e.g. roads to cross, trees, existing conduit, height restrictions)'],
      [6, 2,  'All measurements recorded — fill in Fiber Length, equipment counts on the issue before submitting'],
      [7, 2,  'Minimum 5 site photos taken and ready to upload (required before status can change to Purchase-Requisition)'],
    ],
    'Build Approval Review' => [
      [0, 1,  'Minimum 5 site photos reviewed and acceptable'],
      [1, 1,  'Contractor quote received and attached (PDF)'],
      [2, 1,  'Quoted fibre length matches survey measurement in Fiber Length field'],
      [3, 1,  'Equipment quantities confirmed against survey (Routers, Switches, APs, Media Converters, P2P Radios)'],
      [4, 1,  'Bill of quantities approved'],
      [5, 1,  'Budget within approved limits (add comment if variance approval required)'],
      [6, 1,  'Customer approval for installation route confirmed'],
    ],
    'Fibre Build Checklist' => [
      [0, 2,  'All materials delivered to site and verified against BOQ'],
      [1, 7,  'Fibre cable installed and spliced (document all splice points)'],
      [2, 7,  'Cable management / conduit installed and secured'],
      [3, 7,  'Equipment mounted, powered on and management access confirmed'],
      [4, 7,  'All cables and ports labeled correctly (follow Liquid labeling standard)'],
      [5, 8,  'Fibre test results documented and attached (OTDR or light-level readings required)'],
      [6, 8,  'Site cleaned up and customer premises left in good order'],
    ],
    'Service Handover Checklist' => [
      [0, 1,  'Service connectivity tested end-to-end (ping, traceroute, service-specific test)'],
      [1, 1,  'Speed / performance meets contracted SLA (run speed test, capture screenshot as evidence)'],
      [2, 2,  'Customer walkthrough completed'],
      [3, 2,  'Customer acceptance form signed and attached'],
      [4, 2,  'Support contacts and escalation path document provided to customer'],
      [5, 3,  'As-built drawings attached (fibre route, equipment layout, cable schedule)'],
      [6, 3,  'Handover document signed by customer and Liquid representative'],
    ]
  }.freeze

  def up
    UPDATES.each do |template_title, items|
      template_id_result = execute(
        "SELECT id FROM advanced_checklist_templates WHERE title='#{template_title}' LIMIT 1"
      )
      next if template_id_result.ntuples.zero?

      template_id = template_id_result.first['id']

      items.each do |sort_order, deadline, title|
        execute <<~SQL
          UPDATE advanced_checklist_template_items
          SET deadline = #{deadline}, title = '#{title.gsub("'", "''")}'
          WHERE template_id = #{template_id} AND sort_order = #{sort_order}
        SQL
      end
    end
  end

  def down
    # Deadlines and hints are non-destructive; reverting is unnecessary
  end
end
