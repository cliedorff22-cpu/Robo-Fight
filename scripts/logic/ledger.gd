## ledger.gd - money in and out of a career, with a line for every amount.
## Shared by career.gd (purses, repairs, sponsors) and garage.gd (the parts
## shop), so both write the same ledger the Money tab shows.
class_name Ledger

## Add `amount` (negative to spend) to the career's cash, with a ledger line.
static func pay(career: Dictionary, amount, label: String) -> void:
	if amount == null or float(amount) == 0.0 or is_nan(float(amount)): return
	career.cash += amount
	# Everything ever earned, for the Hall of Fame (the ledger keeps only the latest lines).
	if amount > 0: career.earned = J.g(career, "earned", 0.0) + amount
	career.ledger.append({"season": career.seasonIndex, "round": J.path(career, ["season", "round"], 0), "label": label, "amount": amount})
	if career.ledger.size() > 400:
		career.ledger = career.ledger.slice(career.ledger.size() - 400)
