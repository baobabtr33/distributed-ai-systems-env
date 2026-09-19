# A budget does not cap spend — it emails. The real stop is node_count = 0 in
# tfvars, which is why the alert thresholds are low enough to act on.

data "google_billing_account" "this" {
  billing_account = var.billing_account
}

resource "google_billing_budget" "this" {
  billing_account = data.google_billing_account.this.id
  display_name    = "${var.name}-budget"

  budget_filter {
    projects = ["projects/${var.project_number}"]
  }

  amount {
    specified_amount {
      currency_code = var.currency
      units         = tostring(var.amount)
    }
  }

  dynamic "threshold_rules" {
    for_each = var.thresholds
    content {
      threshold_percent = threshold_rules.value
      spend_basis       = "CURRENT_SPEND"
    }
  }

  # Forecast rather than actual: an L4 pool left running overnight blows the
  # budget before the actual-spend alert would fire.
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  all_updates_rule {
    monitoring_notification_channels = var.notification_channels
    disable_default_iam_recipients   = false
  }
}
