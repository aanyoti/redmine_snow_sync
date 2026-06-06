module SnowSync
  module IssueControllerPatch
    MATERIAL_CF_NAMES = ['Fiber Length', 'Media Converters', 'P2P Radios', 'Routers', 'Switches', 'APs'].freeze
    TRACKER_ID      = 14  # Commercial Orders
    CONTRACTOR_ASGN = 49  # Contractor-Assignment
    PURCHASE_REQ    = 50  # Purchase-Requisition
    BUILD_APPROVAL  = 90  # Build Approval

    def update
      if @issue && @issue.tracker_id == TRACKER_ID
        new_status = params.dig(:issue, :status_id).to_i

        # Gate 1: Contractor-Assignment → Purchase-Requisition
        if @issue.status_id == CONTRACTOR_ASGN && new_status == PURCHASE_REQ
          Thread.current[:snow_pr_filenames] = attachment_filenames_from_params
        end

        # Gate 2: Build Approval → Purchase-Requisition (send-back requires comment)
        if @issue.status_id == BUILD_APPROVAL && new_status == PURCHASE_REQ
          Thread.current[:snow_build_approval_sendback] = @issue.id
        end
      end

      begin
        super
      ensure
        Thread.current[:snow_pr_filenames]            = nil
        Thread.current[:snow_build_approval_sendback] = nil
      end
    end

    private

    def attachment_filenames_from_params
      (params[:attachments] || {}).values
        .select { |a| a.is_a?(Hash) }
        .map    { |a| (a[:filename] || a['filename']).to_s }
        .reject(&:blank?)
    end
  end
end
