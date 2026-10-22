/*
 * Copyright (c) 2011, 2014 Bastien Nocera <hadess@hadess.net>
 *
 * orientation_calc() from the sensorfw package
 * Copyright (C) 2009-2010 Nokia Corporation
 * Authors:
 *   Üstün Ergenoglu <ext-ustun.ergenoglu@nokia.com>
 *   Timo Rongas <ext-timo.2.rongas@nokia.com>
 *   Lihan Guo <lihan.guo@digia.com>
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 3 as published by
 * the Free Software Foundation.
 *
 */

#include <stdint.h>
#include <math.h>
#include <stdlib.h>
#include <glib.h>
#include <limits.h>

#include "orientation.h"

static const char *orientations[] = {
        "undefined",
        "normal",
        "bottom-up",
        "left-up",
        "right-up",
        NULL
};

static const char *tilts[] = {
        "undefined",
        "vertical",
        "tilted-up",
        "tilted-down",
        "face-up",
        "face-down",
        NULL
};

const char *
orientation_to_string (OrientationUp o)
{
        return orientations[o];
}

const char *
tilt_to_string (Tilt t)
{
        return tilts[t];
}

OrientationUp
string_to_orientation (const char *orientation)
{
        int i;

        if (orientation == NULL)
                return ORIENTATION_UNDEFINED;
        for (i = 0; orientations[i] != NULL; i++) {
                if (g_str_equal (orientation, orientations[i]))
                        return i;
        }
        return ORIENTATION_UNDEFINED;
}

Tilt
string_to_tilt (const char *tilt)
{
        int i;

        if (tilt == NULL)
                return TILT_UNDEFINED;
        for (i = 0; tilts[i] != NULL; i++) {
                if (g_str_equal (tilt, tilts[i]))
                        return i;
        }
        return TILT_UNDEFINED;
}
#define RADIANS_TO_DEGREES 180.0/M_PI
#define SAME_AXIS_LIMIT 5

#define THRESHOLD_LANDSCAPE  35
#define THRESHOLD_PORTRAIT  35
#define THRESHOLD_FACE_DOWN  70
#define THRESHOLD_TILT  20
#define TILT_MAX  90

/* Only direction is needed. Normalize input*scale with one common power of
 * two before multiplying, without losing sub-unit SI readings or overflowing
 * on finite opposite-extreme input/scale pairs. The former common positive
 * 256/9.81 factor cancels in the angles; integer quantization is not required.
 * Every nonzero mantissa product is bounded [0.25,1) in magnitude. */
static gboolean
normalize_axes (double in_x, double in_y, double in_z, AccelScale scale,
                double *x, double *y, double *z)
{
        const double inputs[] = { in_x, in_y, in_z };
        const double scales[] = { scale.x, scale.y, scale.z };
        double mantissas[3] = { 0.0, 0.0, 0.0 };
        double normalized[3];
        int exponents[3] = { 0, 0, 0 };
        int maximum = INT_MIN;

        for (guint i = 0; i < G_N_ELEMENTS (inputs); i++) {
                int input_exponent, scale_exponent;
                if (!isfinite (inputs[i]) || !isfinite (scales[i]))
                        return FALSE;
                if (inputs[i] == 0.0 || scales[i] == 0.0)
                        continue;
                mantissas[i] = frexp (inputs[i], &input_exponent) *
                               frexp (scales[i], &scale_exponent);
                exponents[i] = input_exponent + scale_exponent;
                maximum = MAX (maximum, exponents[i]);
        }
        if (maximum == INT_MIN)
                return FALSE;
        for (guint i = 0; i < G_N_ELEMENTS (inputs); i++)
                normalized[i] = mantissas[i] == 0.0 ? 0.0 :
                                scalbn (mantissas[i], exponents[i] - maximum);
        *x = normalized[0];
        *y = normalized[1];
        *z = normalized[2];
        return TRUE;
}

Tilt
tilt_calc (Tilt prev,
           double in_x, double in_y, double in_z,
           AccelScale scale)
{
        Tilt ret = prev;
        double x, y, z;
        double tilt;

        if (!normalize_axes (in_x, in_y, in_z, scale, &x, &y, &z))
                return prev;

        tilt = round (atan2 (z, hypot (x, y)) * RADIANS_TO_DEGREES);

        /* Tilt check */
        if (fabs(tilt) <= THRESHOLD_TILT)
            ret = TILT_VERTICAL;
        else if (fabs(tilt) > THRESHOLD_TILT &&
                   fabs(tilt) < THRESHOLD_FACE_DOWN)
            ret = tilt > 0 ? TILT_UP : TILT_DOWN;
        else if (fabs(tilt) >= THRESHOLD_FACE_DOWN &&
                   fabs(tilt) <= TILT_MAX)
            ret = tilt > 0 ? FACE_UP : FACE_DOWN;
        else
            ret = TILT_UNDEFINED;

        return ret;
}

OrientationUp
orientation_calc (OrientationUp prev,
                  double in_x, double in_y, double in_z,
                  AccelScale scale)
{
        OrientationUp ret = prev;
        double x, y, z;
        double portrait_rotation;
        double landscape_rotation;

        if (!normalize_axes (in_x, in_y, in_z, scale, &x, &y, &z))
                return prev;

        portrait_rotation  = round (atan2 (x, hypot (y, z)) * RADIANS_TO_DEGREES);
        landscape_rotation = round (atan2 (y, hypot (x, z)) * RADIANS_TO_DEGREES);

        /* Don't change orientation if we are on the common border of two thresholds */
        if (fabs(portrait_rotation) > THRESHOLD_PORTRAIT && fabs(landscape_rotation) > THRESHOLD_LANDSCAPE)
                return prev;

        /* Portrait check */
        if (fabs(portrait_rotation) > THRESHOLD_PORTRAIT) {
                ret = (portrait_rotation > 0) ? ORIENTATION_LEFT_UP : ORIENTATION_RIGHT_UP;

                /* Some threshold to switching between portrait modes */
                if (prev == ORIENTATION_LEFT_UP || prev == ORIENTATION_RIGHT_UP) {
                        if (fabs(portrait_rotation) < SAME_AXIS_LIMIT) {
                                ret = prev;
                        }
                }

        } else {
                /* Landscape check */
                if (fabs(landscape_rotation) > THRESHOLD_LANDSCAPE) {
                        ret = (landscape_rotation > 0) ? ORIENTATION_BOTTOM_UP : ORIENTATION_NORMAL;

                        /* Some threshold to switching between landscape modes */
                        if (prev == ORIENTATION_BOTTOM_UP || prev == ORIENTATION_NORMAL) {
                                if (fabs(landscape_rotation) < SAME_AXIS_LIMIT) {
                                        ret = prev;
                                }
                        }
                }
        }

        return ret;
}
