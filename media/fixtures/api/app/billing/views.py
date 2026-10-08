from flask import Blueprint, flash, redirect, render_template
from flask_babel import gettext as _
from flask_login import current_user, login_required

from app.models import Plan

bp = Blueprint("billing", __name__)


@bp.post("/billing/upgrade/<plan_id>")
@login_required
def upgrade(plan_id: str):
    plan = Plan.query.get(plan_id)
    if plan is None:
        flash(_("That plan is no longer available."), "error")
        return redirect("/billing")

    if not current_user.has_payment_method:
        flash(_("Add a card to continue."), "warning")
        return redirect("/billing/payment")

    current_user.subscribe(plan)
    flash(_("Welcome to the %(plan)s plan.", plan=plan.name))
    return render_template("done.html", title=_("Thanks for upgrading!"))
