/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef _LIBSSC_SENSOR_RETIREMENT_H_
#define _LIBSSC_SENSOR_RETIREMENT_H_

#include <glib-object.h>

G_BEGIN_DECLS

/**
 * SSCSensorRetirementReceipt:
 *
 * Immutable evidence that the admitted libssc-owned local backend graph has
 * retired. Actual release/close errors remain independent values inside the
 * receipt. This does not establish physical DSP quiescence, drain unrelated
 * application callbacks or certify every provider-internal reference/socket.
 *
 * Since: 0.4.5
 */
typedef struct _SSCSensorRetirementReceipt SSCSensorRetirementReceipt;

#define SSC_TYPE_SENSOR_RETIREMENT_RECEIPT (ssc_sensor_retirement_receipt_get_type ())
GType ssc_sensor_retirement_receipt_get_type (void) G_GNUC_CONST;

/**
 * ssc_sensor_retirement_receipt_copy:
 * @receipt: a terminal receipt
 *
 * Returns: (transfer full): an independent immutable copy
 * Since: 0.4.5
 */
SSCSensorRetirementReceipt *ssc_sensor_retirement_receipt_copy (
	const SSCSensorRetirementReceipt *receipt);

/**
 * ssc_sensor_retirement_receipt_free:
 * @receipt: (nullable) (transfer full): a receipt to release
 *
 * Since: 0.4.5
 */
void ssc_sensor_retirement_receipt_free (SSCSensorRetirementReceipt *receipt);

/**
 * ssc_sensor_retirement_receipt_get_local_complete:
 * @receipt: a terminal receipt
 *
 * Returns: %TRUE for every valid receipt; no incomplete receipt is published
 * Since: 0.4.5
 */
gboolean ssc_sensor_retirement_receipt_get_local_complete (
	const SSCSensorRetirementReceipt *receipt);

/**
 * ssc_sensor_retirement_receipt_dup_release_error:
 * @receipt: a terminal receipt
 *
 * Returns: (transfer full) (nullable): the first actual release error, or %NULL
 * Since: 0.4.5
 */
GError *ssc_sensor_retirement_receipt_dup_release_error (
	const SSCSensorRetirementReceipt *receipt);

/**
 * ssc_sensor_retirement_receipt_dup_close_error:
 * @receipt: a terminal receipt
 *
 * Returns: (transfer full) (nullable): the first actual close error, or %NULL
 * Since: 0.4.5
 */
GError *ssc_sensor_retirement_receipt_dup_close_error (
	const SSCSensorRetirementReceipt *receipt);

G_DEFINE_AUTOPTR_CLEANUP_FUNC (SSCSensorRetirementReceipt,
	ssc_sensor_retirement_receipt_free)

G_END_DECLS
#endif
