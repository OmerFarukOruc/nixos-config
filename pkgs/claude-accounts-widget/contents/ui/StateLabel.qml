import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3

import "Logic.js" as Logic

PlasmaComponents3.Label {
    property string acctState

    text: Logic.stateText(acctState)
    color: acctState === "ok" ? Kirigami.Theme.positiveTextColor
         : acctState === "expiring" ? Kirigami.Theme.neutralTextColor
         : Kirigami.Theme.negativeTextColor
}
