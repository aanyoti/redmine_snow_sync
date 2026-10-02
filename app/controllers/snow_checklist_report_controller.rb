class SnowChecklistReportController < ApplicationController
  before_action :require_login

  def index
    conn = ActiveRecord::Base.connection

    @filter_checklist = params[:checklist].presence
    @filter_status    = params[:status].presence
    @filter_assignee  = params[:assignee].presence

    where_clauses = []
    where_clauses << ActiveRecord::Base.sanitize_sql_array(["checklist_title = ?", @filter_checklist]) if @filter_checklist
    where_clauses << ActiveRecord::Base.sanitize_sql_array(["status_name = ?", @filter_status])        if @filter_status
    where_clauses << ActiveRecord::Base.sanitize_sql_array(["assigned_to_name = ?", @filter_assignee]) if @filter_assignee

    where_sql = where_clauses.any? ? "WHERE #{where_clauses.join(' AND ')}" : ""

    @rows = conn.select_all("SELECT * FROM vw_checklist_compliance #{where_sql}").to_a

    @summary = {
      total_checklists:  @rows.size,
      fully_completed:   @rows.count { |r| r['completion_pct'].to_f == 100.0 },
      in_progress:       @rows.count { |r| r['completion_pct'].to_f > 0 && r['completion_pct'].to_f < 100.0 },
      not_started:       @rows.count { |r| r['completion_pct'].to_f == 0 },
      overdue_items:     @rows.sum { |r| r['overdue_items'].to_i },
      total_items:       @rows.sum { |r| r['total_items'].to_i },
      completed_items:   @rows.sum { |r| r['completed_items'].to_i },
    }
    @summary[:overall_pct] = @summary[:total_items] > 0 ?
      (100.0 * @summary[:completed_items] / @summary[:total_items]).round(1) : 0

    by_checklist = @rows.group_by { |r| r['checklist_title'] }
    @by_checklist = by_checklist.map do |title, rows|
      total    = rows.sum { |r| r['total_items'].to_i }
      done     = rows.sum { |r| r['completed_items'].to_i }
      overdue  = rows.sum { |r| r['overdue_items'].to_i }
      { title: title, count: rows.size, total: total, done: done, overdue: overdue,
        pct: total > 0 ? (100.0 * done / total).round(1) : 0 }
    end.sort_by { |r| -r[:count] }

    by_assignee = @rows.group_by { |r| r['assigned_to_name'] }
    @by_assignee = by_assignee.map do |name, rows|
      total   = rows.sum { |r| r['total_items'].to_i }
      done    = rows.sum { |r| r['completed_items'].to_i }
      overdue = rows.sum { |r| r['overdue_items'].to_i }
      { name: name, count: rows.size, total: total, done: done, overdue: overdue,
        pct: total > 0 ? (100.0 * done / total).round(1) : 0 }
    end.sort_by { |r| -r[:count] }

    @checklist_names = conn.select_values("SELECT DISTINCT checklist_title FROM vw_checklist_compliance ORDER BY 1")
    @status_names    = conn.select_values("SELECT DISTINCT status_name FROM vw_checklist_compliance ORDER BY 1")
    @assignee_names  = conn.select_values("SELECT DISTINCT assigned_to_name FROM vw_checklist_compliance ORDER BY 1")
  end
end
