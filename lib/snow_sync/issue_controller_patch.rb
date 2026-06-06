module SnowSync
  module IssueControllerPatch
    MATERIAL_CF_NAMES = ['Fiber Length', 'Media Converters', 'P2P Radios', 'Routers', 'Switches', 'APs'].freeze
    FROM_STATUS = 49  # Contractor-Assignment
    TO_STATUS   = 50  # Purchase-Requisition
    TRACKER_ID  = 14  # Commercial Orders

    def update
      if @issue &&
         @issue.tracker_id == TRACKER_ID &&
         @issue.status_id  == FROM_STATUS &&
         params.dig(:issue, :status_id).to_i == TO_STATUS

        incoming = (params[:attachments] || {}).values
                     .select { |a| a.is_a?(Hash) }
                     .map    { |a| (a[:filename] || a['filename']).to_s }
                     .reject(&:blank?)

        Thread.current[:snow_pr_filenames] = incoming
      end

      begin
        super
      ensure
        Thread.current[:snow_pr_filenames] = nil
      end
    end
  end
end
