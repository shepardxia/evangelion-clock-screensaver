"use strict";

function element(id) {
	return document.getElementById(id);
}

function setDigit(number, text) {
	element("clock-digit-" + number).children[0].textContent = text;
}

function setFixedTimeForDebug() {
	setDigit(1, 2);
	setDigit(2, 3);
	setDigit(3, 4);
	setDigit(4, 8);
	setDigit(5, 2);
	setDigit(6, 3);
}

function updateClock() {
	var date = new Date();

	var hoursInt = date.getHours();
	var minutesInt = date.getMinutes();
	var secondsInt = date.getSeconds();

	var hoursString = hoursInt + "";
	var minutesString = minutesInt + "";
	var secondsString = secondsInt + "";

	if (hoursInt < 10) {
		hoursString = "0" + hoursInt;
	}
	if (minutesString < 10) {
		minutesString = "0" + minutesString;
	}
	if (secondsString < 10) {
		secondsString = "0" + secondsString;
	}

	setDigit(1, hoursString.charAt(0));
	setDigit(2, hoursString.charAt(1));
	setDigit(3, minutesString.charAt(0));
	setDigit(4, minutesString.charAt(1));
	setDigit(5, secondsString.charAt(0));
	setDigit(6, secondsString.charAt(1));
}

// The panel keeps the orientation it had in the room at the first reading, so it turns against the
// laptop, from the style's spawn angle, at most REACH degrees along the iOS rubber-band curve.
var REACH = 25;
var STIFFNESS = 0.55; // iOS overscroll constant, and so the gain near center
var panel = document.querySelector(".gui svg");

// Since the first reading: its elevation, the latest azimuth, and the turn so far, unwrapped so that
// facing directly away cannot flip sides.
var held = null;

function rubberBand(angle) {
	var pulled = REACH * (1 - 1 / (STIFFNESS * Math.abs(angle) / REACH + 1));
	return angle < 0 ? -pulled : pulled;
}

function degrees(radians) {
	return radians * 180 / Math.PI;
}

// The host calls this with the screen normal from wabe (world frame, Z up), and with nothing when
// the daemon goes away.
function wabePose(nx, ny, nz) {
	if (nx === undefined) {
		held = null;
		panel.style.removeProperty("--yaw");
		panel.style.removeProperty("--pitch");
		return;
	}
	var azimuth = degrees(Math.atan2(ny, nx));
	var elevation = degrees(Math.asin(nz));
	if (!held) {
		held = {
			elevation: elevation,
			azimuth: azimuth,
			turn: 0
		};
	}
	var step = azimuth - held.azimuth;
	held.turn += step - 360 * Math.round(step / 360);
	held.azimuth = azimuth;

	panel.style.setProperty("--yaw", -rubberBand(held.turn) + "deg");
	panel.style.setProperty("--pitch", -rubberBand(elevation - held.elevation) + "deg");
}

setInterval(updateClock, 1000);
updateClock();

// setFixedTimeForDebug();
