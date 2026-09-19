variable "name" {
  type        = string
  description = "Prefix for the budget display name."
}

variable "billing_account" {
  type        = string
  description = "Billing account id, e.g. 0X0X0X-0X0X0X-0X0X0X."
}

variable "project_number" {
  type        = string
  description = "Project NUMBER, not id: budget filters take the number."
}

variable "amount" {
  type        = number
  description = "Budget in whole currency units. docs/PLAN.md sets the project ceiling at 50."
  default     = 50
}

variable "currency" {
  type        = string
  description = "Currency code. Must match the billing account's."
  default     = "USD"
}

variable "thresholds" {
  type        = list(number)
  description = "Actual-spend alert fractions. Defaults are the $25 and $40 marks from docs/PLAN.md."
  default     = [0.5, 0.8]
}

variable "notification_channels" {
  type        = list(string)
  description = "Monitoring notification channel ids. Empty still emails the billing account admins."
  default     = []
}
