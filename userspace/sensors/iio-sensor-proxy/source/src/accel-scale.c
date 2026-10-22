/*
 * Copyright (c) 2020 Bastien Nocera <hadess@hadess.net>
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 3 as published by
 * the Free Software Foundation.
 *
 */

#include <glib.h>
#include <math.h>

#include "accel-scale.h"

void
reset_accel_scale (AccelScale *scale)
{
	set_accel_scale (scale, 1.0);
}

void
set_accel_scale (AccelScale *scale,
		 double     value)
{
	g_return_if_fail (scale != NULL);
	g_return_if_fail (value != 0.0);
	g_return_if_fail (isfinite (value));

	scale->x = scale->y = scale->z = value;
}

void
copy_accel_scale (AccelScale *target,
		  AccelScale  source)
{
	g_return_if_fail (target != NULL);

	target->x = source.x;
	target->y = source.y;
	target->z = source.z;
}

gboolean
parse_accel_scale (const char *text, double *value)
{
	const char *start;
	char *end;
	double parsed;

	g_return_val_if_fail (value != NULL, FALSE);
	if (!text)
		return FALSE;
	start = text;
	while (g_ascii_isspace (*start))
		start++;
	if (*start == '+' || *start == '-')
		start++;
	if (start[0] == '0' && (start[1] == 'x' || start[1] == 'X'))
		return FALSE;
	parsed = g_ascii_strtod (text, &end);
	/* Nonzero subnormals are valid. Zero is not a calibration scale, whether
	 * literal or rounded there by underflow; overflow is non-finite. */
	if (end == text || !isfinite (parsed) || parsed == 0.0)
		return FALSE;
	while (g_ascii_isspace (*end))
		end++;
	if (*end != '\0')
		return FALSE;
	*value = parsed;
	return TRUE;
}
