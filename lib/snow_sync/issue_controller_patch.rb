module SnowSync
  module IssueControllerPatch
    MATERIAL_CF_NAMES  = ['Fiber Length', 'Media Converters', 'P2P Radios', 'Routers', 'Switches', 'APs'].freeze
    TRACKER_ID         = 14  # Commercial Orders
    PROCUREMENT_TRACKER = 17 # Procurement
    CONTRACTOR_ASGN    = 49  # Contractor-Assignment
    PURCHASE_REQ       = 50  # Purchase-Requisition
    FIBER_BUILD        = 51  # Fiber Build
    BUILD_APPROVAL     = 90  # Build Approval
    PR_RAISED          = 72  # Procurement: PR Raised
    PO_GENERATED       = 74  # Procurement: PO Generated
    PROC_CLOSED        = 75  # Procurement: Procurement Closed

    def update
      if @issue
        new_status = params.dig(:issue, :status_id).to_i

        if @issue.tracker_id == TRACKER_ID
          # Gate 1: Purchase-Requisition → Build Approval (contractor must have filled CFs + photos + PDF)
          if @issue.status_id == PURCHASE_REQ && new_status == BUILD_APPROVAL
            Thread.current[:snow_pr_filenames] = attachment_filenames_from_params
          end

          # Gate 2: Build Approval → Purchase-Requisition (send-back requires comment)
          if @issue.status_id == BUILD_APPROVAL && new_status == PURCHASE_REQ
            Thread.current[:snow_build_approval_sendback] = @issue.id
          end
        end

        if @issue.tracker_id == PROCUREMENT_TRACKER
          # Gate 3: PR Raised → PO Generated (PR Reference must be filled)
          if @issue.status_id == PR_RAISED && new_status == PO_GENERATED
            Thread.current[:snow_procurement_pr_ref] = @issue.id
          end

          # Gate 4: PO Generated → Procurement Closed (PO Number + PO PDF required)
          if @issue.status_id == PO_GENERATED && new_status == PROC_CLOSED
            Thread.current[:snow_po_filenames] = attachment_filenames_from_params
          end
        end
      end

      begin
        super
      ensure
        Thread.current[:snow_pr_filenames]            = nil
        Thread.current[:snow_build_approval_sendback] = nil
        Thread.current[:snow_procurement_pr_ref]      = nil
        Thread.current[:snow_po_filenames]            = nil
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
