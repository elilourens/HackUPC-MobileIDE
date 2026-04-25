"""
Structured financial summary aggregation for OpenBanking / statement JSON.

Produces a deterministic, reproducible summary per account with:
- time_window, totals (inflow/outflow/net), income/spending breakdowns,
- recurring merchants (cadence + avg amount), runway (CURRENT only), warnings.
"""

from __future__ import annotations

from collections import defaultdict
from datetime import date, datetime, timedelta
from typing import Any

# ---------------------------------------------------------------------------
# Normalization: support both "statements" and "accounts" (OpenBanking) shapes
# ---------------------------------------------------------------------------

PAYMENT_LIKE_DESCRIPTIONS = frozenset(
    s.strip().upper()
    for s in (
        "DIRECT DEBIT PAYMENT",
        "FASTER PAYMENT RECEIVED",
        "PAYMENT RECEIVED",
        "BANK TRANSFER",
        "STANDING ORDER",
        "DD PAYMENT",
        "CARD PAYMENT",
    )
)


def _is_credit_account(blob: dict) -> bool:
    account = blob.get("account") or {}
    at = (account.get("account_type") or blob.get("account_type") or "").upper()
    return at == "CREDIT"


def _parse_balance(blob: dict) -> tuple[float | None, float | None]:
    """Return (current, available). Supports balance as dict or list of dicts."""
    balance = blob.get("balance")
    current = available = None
    if balance is None:
        return None, None
    if isinstance(balance, dict):
        current = balance.get("current")
        available = balance.get("available")
        return current, available
    if isinstance(balance, list) and balance:
        first = balance[0]
        if isinstance(first, dict):
            current = first.get("current")
            available = first.get("available")
    return current, available


def _txn_date(txn: dict) -> date | None:
    ts = txn.get("timestamp") or txn.get("date")
    if not ts:
        return None
    try:
        dt = datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
        return dt.date()
    except (ValueError, TypeError):
        return None


def _amount(txn: dict) -> float:
    return float(txn.get("amount") or 0)


def _description_looks_like_payment(description: str, category: str) -> bool:
    if (category or "").upper() == "PAYMENT":
        return True
    desc_upper = (description or "").strip().upper()
    if desc_upper in PAYMENT_LIKE_DESCRIPTIONS:
        return True
    if "PAYMENT" in desc_upper and ("RECEIVED" in desc_upper or "DEBIT" in desc_upper):
        return True
    return False


def _classify_credit_side(txn: dict, account_type: str) -> str:
    """For CREDIT-type txns: 'repayment' or 'income'. For DEBIT: not used (outflow)."""
    category = (txn.get("transaction_category") or "").upper()
    description = (txn.get("description") or "").strip()
    if _description_looks_like_payment(description, category):
        return "repayment"
    return "income"


def _normalize_accounts(data: dict) -> list[dict]:
    """Produce a list of account blobs with balance_current, balance_available, transactions."""
    out = []
    # OpenBanking: data.accounts[] with balance, transactions
    accounts = data.get("accounts") or data.get("statements") or []
    for i, blob in enumerate(accounts):
        current, available = _parse_balance(blob)
        txns = blob.get("transactions") or []
        account_id = blob.get("account_id") or (blob.get("account") or {}).get("account_id") or f"account_{i+1}"
        account_type = "CREDIT" if _is_credit_account(blob) else "CURRENT"
        currency = (blob.get("currency") or (blob.get("account") or {}).get("currency") or "GBP")
        out.append({
            "account_id": account_id,
            "account_type": account_type,
            "currency": currency,
            "balance_current": current if current is not None else None,
            "balance_available": available if available is not None else None,
            "transactions": txns,
        })
    return out


# ---------------------------------------------------------------------------
# Income / spending heuristics (description + category)
# ---------------------------------------------------------------------------

def _match_income_salary(description: str, category: str) -> bool:
    d = (description or "").upper()
    c = (category or "").upper()
    if c in ("INCOME", "SALARY", "PAYROLL"):
        return True
    for k in ("SALARY", "PAYROLL", "WAGES", "EMPLOYER", "PAY "):
        if k in d:
            return True
    return False


def _match_income_benefits(description: str, category: str) -> bool:
    d = (description or "").upper()
    for k in ("TAX CREDIT", "UNIVERSAL CREDIT", "BENEFIT", "DWP", "HMRC"):
        if k in d:
            return True
    return False


def _match_transfer_in(description: str, category: str, amount: float) -> bool:
    if amount <= 0:
        return False
    c = (category or "").upper()
    if c == "TRANSFER":
        return True
    d = (description or "").upper()
    if "TRANSFER" in d and "IN" in d:
        return True
    return False


def _match_rent(description: str, category: str) -> bool:
    d = (description or "").upper()
    c = (category or "").upper()
    if "RENT" in c or "MORTGAGE" in c or "HOUSING" in c:
        return True
    for k in ("RENT", "LANDLORD", "LETTINGS", "MORTGAGE", "COUNCIL TAX"):
        if k in d:
            return True
    return False


def _match_groceries(description: str, category: str) -> bool:
    d = (description or "").upper()
    c = (category or "").upper()
    if c in ("GROCERIES", "FOOD", "SUPERMARKET"):
        return True
    for k in ("TESCO", "SAINSBURY", "ASDA", "MORRISONS", "WAITROSE", "ALDI", "LIDL", "CO-OP", "GROCERY", "SUPERMARKET"):
        if k in d:
            return True
    return False


def _match_transport(description: str, category: str) -> bool:
    d = (description or "").upper()
    c = (category or "").upper()
    if c in ("TRANSPORT", "FUEL", "PARKING"):
        return True
    for k in ("TFL", "UBER", "BUS", "TRAIN", "PETROL", "SHELL", "BP ", "PARKING", "TUBE"):
        if k in d:
            return True
    return False


def _match_subscription(description: str, category: str) -> bool:
    c = (category or "").upper()
    if c in ("SUBSCRIPTION", "RECURRING"):
        return True
    d = (description or "").upper()
    for k in ("NETFLIX", "SPOTIFY", "AMAZON PRIME", "APPLE", "DISNEY", "SUBSCRIPTION", "MONTHLY"):
        if k in d:
            return True
    return False


# ---------------------------------------------------------------------------
# Time window: last 30 days from latest transaction
# ---------------------------------------------------------------------------

def _window_30d(txns: list[dict]) -> tuple[list[dict], date | None, date | None]:
    if not txns:
        return [], None, None
    dates = [_txn_date(t) for t in txns]
    valid = [d for d in dates if d is not None]
    if not valid:
        return txns, None, None
    end = max(valid)
    start = end - timedelta(days=30)
    windowed = [t for t in txns if _txn_date(t) and start <= _txn_date(t) <= end]
    return windowed, start, end


# ---------------------------------------------------------------------------
# Recurring merchants: same description in 2+ months, estimate cadence + avg
# ---------------------------------------------------------------------------

def _recurring_merchants_with_cadence(txns: list[dict], window_start: date | None, window_end: date | None) -> list[dict]:
    if not txns or not window_end:
        return []
    by_desc_month: dict[str, list[tuple[date, float]]] = defaultdict(list)
    for t in txns:
        d = _txn_date(t)
        if not d:
            continue
        desc = (t.get("description") or "").strip() or "(no description)"
        amt = abs(_amount(t))
        by_desc_month[desc].append((d, amt))
    # Must appear in at least 2 distinct calendar months
    result = []
    for desc, date_amounts in by_desc_month.items():
        months = set((d.year, d.month) for d, _ in date_amounts)
        if len(months) < 2:
            continue
        amounts = [a for _, a in date_amounts]
        avg = sum(amounts) / len(amounts) if amounts else 0
        # Rough cadence: avg days between occurrences
        dates_sorted = sorted(set(d for d, _ in date_amounts))
        if len(dates_sorted) >= 2:
            gaps = [(dates_sorted[i + 1] - dates_sorted[i]).days for i in range(len(dates_sorted) - 1)]
            avg_days = sum(gaps) / len(gaps)
            if avg_days <= 35:
                cadence = "~monthly"
            elif avg_days <= 45:
                cadence = "~monthly"
            else:
                cadence = f"~every {int(avg_days)} days"
        else:
            cadence = "recurring"
        result.append({"description": desc, "cadence": cadence, "avg_amount": round(avg, 2), "count": len(date_amounts)})
    return result[:25]


# ---------------------------------------------------------------------------
# Build structured summary per account
# ---------------------------------------------------------------------------

def build_account_summaries(data: dict) -> list[dict]:
    """
    Build one structured summary object per account. Works with both
    data.statements (test format) and data.accounts (OpenBanking).
    """
    accounts = _normalize_accounts(data)
    result = []
    seen_timestamps: dict[str, set[str]] = defaultdict(set)

    for acc in accounts:
        account_id = acc["account_id"]
        account_type = acc["account_type"]
        currency = acc["currency"]
        balance_current = acc["balance_current"]
        balance_available = acc["balance_available"]
        txns = acc["transactions"]

        windowed, window_start, window_end = _window_30d(txns)
        warnings: list[str] = []

        # Totals: inflow = sum(positive), outflow = abs(sum(negative))
        total_inflow = 0.0
        total_outflow = 0.0
        for t in windowed:
            amt = _amount(t)
            if amt > 0:
                total_inflow += amt
            else:
                total_outflow += abs(amt)
        net_flow = round(total_inflow - total_outflow, 2)
        total_inflow = round(total_inflow, 2)
        total_outflow = round(total_outflow, 2)

        # Income breakdown (only positive amounts; for CREDIT, separate repayments)
        salary_income = 0.0
        benefits_income = 0.0
        transfers_in = 0.0
        repayments_in = 0.0
        other_income = 0.0

        for t in windowed:
            amt = _amount(t)
            if amt <= 0:
                continue
            txn_type = (t.get("transaction_type") or "").upper()
            desc = (t.get("description") or "").strip()
            cat = (t.get("transaction_category") or "").upper()
            if txn_type != "CREDIT":
                other_income += amt
                continue
            kind = _classify_credit_side(t, account_type)
            if account_type == "CREDIT" and kind == "repayment":
                repayments_in += amt
                continue
            if _match_income_salary(desc, cat):
                salary_income += amt
            elif _match_income_benefits(desc, cat):
                benefits_income += amt
            elif _match_transfer_in(desc, cat, amt):
                transfers_in += amt
            else:
                other_income += amt

        income_breakdown = {
            "salary_income": round(salary_income, 2),
            "benefits_income": round(benefits_income, 2),
            "transfers_in": round(transfers_in, 2),
            "repayments_in": round(repayments_in, 2),
            "other_income": round(other_income, 2),
        }

        # Spending breakdown (outflows)
        rent_mortgage = 0.0
        groceries_food = 0.0
        transport = 0.0
        subscriptions = 0.0
        other = 0.0
        for t in windowed:
            amt = _amount(t)
            if amt >= 0:
                continue
            abs_amt = abs(amt)
            desc = (t.get("description") or "").strip()
            cat = (t.get("transaction_category") or "").upper()
            if _match_rent(desc, cat):
                rent_mortgage += abs_amt
            elif _match_groceries(desc, cat):
                groceries_food += abs_amt
            elif _match_transport(desc, cat):
                transport += abs_amt
            elif _match_subscription(desc, cat):
                subscriptions += abs_amt
            else:
                other += abs_amt

        spending_breakdown = {
            "rent_mortgage": round(rent_mortgage, 2),
            "groceries_food": round(groceries_food, 2),
            "transport": round(transport, 2),
            "subscriptions": round(subscriptions, 2),
            "other": round(other, 2),
        }

        recurring = _recurring_merchants_with_cadence(txns, window_start, window_end)

        # Warnings
        if account_type == "CREDIT":
            warnings.append("Credit-card runway is not meaningful; balance is outstanding debt, not savings.")
        if balance_current is not None and balance_available is None and account_type == "CURRENT":
            warnings.append("Only current balance provided; available balance unknown — runway may overstate.")
        for t in windowed:
            ts = t.get("timestamp") or t.get("date")
            if ts and account_id:
                if ts in seen_timestamps[account_id]:
                    warnings.append("Duplicate timestamps detected; totals may be inflated.")
                    break
                seen_timestamps[account_id].add(ts)

        # Runway: only for CURRENT, only when we have positive funds and outflow
        estimated_monthly_outflow = total_outflow  # 30d window => use as monthly proxy
        runway_months = None
        runway_note = None
        if account_type == "CURRENT":
            funds = balance_available if balance_available is not None else balance_current
            if funds is not None and estimated_monthly_outflow is not None and estimated_monthly_outflow >= 1:
                try:
                    f = float(funds)
                    if f > 0:
                        runway_months = round(f / max(float(estimated_monthly_outflow), 1), 1)
                except (TypeError, ValueError):
                    pass
            if runway_months is None and (balance_current is not None or balance_available is not None):
                runway_note = "Runway not computed: need positive available/current balance and non-zero outflow in window."

        result.append({
            "account_id": account_id,
            "account_type": account_type,
            "currency": currency,
            "balance_current": balance_current,
            "balance_available": balance_available,
            "time_window_start": window_start.isoformat() if window_start else None,
            "time_window_end": window_end.isoformat() if window_end else None,
            "totals": {
                "total_inflow": total_inflow,
                "total_outflow": total_outflow,
                "net_flow": net_flow,
            },
            "income_breakdown": income_breakdown,
            "spending_breakdown": spending_breakdown,
            "recurring_merchants": recurring,
            "warnings": list(dict.fromkeys(warnings)),
            "runway_months": runway_months,
            "runway_note": runway_note,
        })
    return result


# ---------------------------------------------------------------------------
# Human-readable summary text from structured summaries
# ---------------------------------------------------------------------------

def format_summary_for_display(summaries: list[dict]) -> str:
    """
    Produce explicit, reproducible human-readable summary from structured summaries.
    Includes: what balance represents, exact window, totals with currency,
    runway (CURRENT only), rent callout, definitions.
    """
    if not summaries:
        return "No accounts or statements found in the data."
    lines = []
    for s in summaries:
        acc_id = s.get("account_id") or "Account"
        acc_type = s.get("account_type") or "CURRENT"
        currency = s.get("currency") or "GBP"
        curr_sym = "£" if currency == "GBP" else ("$" if currency == "USD" else currency + " ")

        lines.append(f"## {acc_id} ({acc_type})")
        # What this balance represents
        if acc_type == "CREDIT":
            lines.append("- **What this balance represents:** Outstanding card balance (debt). Not savings or available funds.")
        else:
            if s.get("balance_available") is not None:
                lines.append("- **What this balance represents:** Available funds (spendable). Current balance may differ.")
            elif s.get("balance_current") is not None:
                lines.append("- **What this balance represents:** Current balance (available balance not provided).")
            else:
                lines.append("- **What this balance represents:** No balance data in feed.")

        # Window
        start = s.get("time_window_start")
        end = s.get("time_window_end")
        if start and end:
            lines.append(f"- **30d window:** {start} → {end} (all totals below are for this period).")

        # Balances
        bc = s.get("balance_current")
        ba = s.get("balance_available")
        if bc is not None:
            lines.append(f"- **Current balance:** {curr_sym}{float(bc):,.2f}")
        if ba is not None:
            lines.append(f"- **Available balance:** {curr_sym}{float(ba):,.2f}")

        # Totals (explicit definitions)
        tot = s.get("totals") or {}
        lines.append(f"- **Total inflow (credits in window):** {curr_sym}{tot.get('total_inflow', 0):,.2f}")
        lines.append(f"- **Total outflow (debits in window):** {curr_sym}{tot.get('total_outflow', 0):,.2f}")
        lines.append(f"- **Net flow (inflow − outflow):** {curr_sym}{tot.get('net_flow', 0):,.2f}")

        # Income breakdown (what's included/excluded)
        inc = s.get("income_breakdown") or {}
        if any(inc.values()):
            lines.append("- **Income breakdown (how computed):**")
            if acc_type == "CREDIT":
                lines.append(f"  - Repayments (payments to card, not income): {curr_sym}{inc.get('repayments_in', 0):,.2f}")
            lines.append(f"  - Salary/payroll (description/category match): {curr_sym}{inc.get('salary_income', 0):,.2f}")
            lines.append(f"  - Benefits (e.g. tax credit, DWP): {curr_sym}{inc.get('benefits_income', 0):,.2f}")
            lines.append(f"  - Transfers in: {curr_sym}{inc.get('transfers_in', 0):,.2f}")
            lines.append(f"  - Other income: {curr_sym}{inc.get('other_income', 0):,.2f}")

        # Spending breakdown
        spend = s.get("spending_breakdown") or {}
        if any(spend.values()):
            lines.append("- **Spending breakdown:**")
            lines.append(f"  - Rent/mortgage (description/category): {curr_sym}{spend.get('rent_mortgage', 0):,.2f}")
            lines.append(f"  - Groceries/food: {curr_sym}{spend.get('groceries_food', 0):,.2f}")
            lines.append(f"  - Transport: {curr_sym}{spend.get('transport', 0):,.2f}")
            lines.append(f"  - Subscriptions: {curr_sym}{spend.get('subscriptions', 0):,.2f}")
            lines.append(f"  - Other: {curr_sym}{spend.get('other', 0):,.2f}")
            # Rent callout
            rent = spend.get("rent_mortgage") or 0
            if rent > 0:
                lines.append(f"  - **Rent/mortgage detected:** {curr_sym}{rent:,.2f} in this 30d window (treat as ~monthly if recurring).")

        # Runway (CURRENT only)
        if acc_type == "CURRENT":
            rn = s.get("runway_months")
            rnote = s.get("runway_note")
            if rn is not None:
                lines.append(f"- **Runway:** {rn} months (formula: available_funds / max(monthly_outflow, 1); monthly outflow approximated by this window's total outflow).")
            elif rnote:
                lines.append(f"- **Runway:** {rnote}")

        # Recurring merchants
        rec = s.get("recurring_merchants") or []
        if rec:
            lines.append("- **Recurring merchants (2+ months in data):**")
            for r in rec[:10]:
                lines.append(f"  - {r['description']}: {r['cadence']}, avg {curr_sym}{r['avg_amount']:,.2f}")

        # Warnings
        warn = s.get("warnings") or []
        if warn:
            lines.append("- **Warnings:** " + "; ".join(warn))

        lines.append("")
    return "\n".join(lines).strip()
