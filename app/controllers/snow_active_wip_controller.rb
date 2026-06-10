class SnowActiveWipController < ApplicationController
  before_action :require_login
  before_action :check_access

  def set
    issue = Issue.find(params[:issue_id])
    cf    = IssueCustomField.find_by(name: 'Active WIP')
    return render json: { error: 'Active WIP field not configured' }, status: :not_found unless cf

    value   = params[:value].to_s == '1' ? '1' : '0'
    cv      = CustomValue.find_or_initialize_by(
      customized_type: 'Issue',
      customized_id:   issue.id,
      custom_field_id: cf.id
    )
    old_val = cv.value.to_s
    cv.value = value
    cv.save!

    # Journal entry — shows as "Active WIP changed from No to Yes" in history
    journal = issue.journals.build(user: User.current)
    journal.details.build(property: 'cf', prop_key: cf.id.to_s,
                          old_value: old_val, value: value)
    journal.save!

    render json: { status: 'ok', value: value }
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Issue not found' }, status: :not_found
  end

  private

  def check_access
    unless SnowSync::ActiveWipHelper.authorized?(User.current)
      render json: { error: 'Not authorised to set Active WIP' }, status: :forbidden
    end
  end
end
