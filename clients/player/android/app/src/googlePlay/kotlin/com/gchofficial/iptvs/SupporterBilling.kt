package com.gchofficial.iptvs

import android.app.Activity
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal class SupporterBilling(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "iptvs/google_play_supporter")
    private val waiting = mutableListOf<(Boolean) -> Unit>()
    private val client = BillingClient.newBuilder(activity.applicationContext)
        .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())
        .setListener { result, purchases ->
            activity.runOnUiThread {
                if (!disposed) channel.invokeMethod("updated", mapOf(
                    "result" to result.responseCode,
                    "purchases" to purchases.orEmpty().map(::purchase),
                ))
            }
        }
        .build()
    private var disposed = false

    init {
        channel.setMethodCallHandler(::handle)
    }

    private fun ready(next: (Boolean) -> Unit) {
        if (client.isReady) {
            next(true)
            return
        }
        waiting.add(next)
        if (waiting.size > 1) return
        client.startConnection(object : BillingClientStateListener {
            override fun onBillingSetupFinished(result: BillingResult) = finish(result.responseCode == 0)
            override fun onBillingServiceDisconnected() = finish(false)

            private fun finish(connected: Boolean) = activity.runOnUiThread {
                val callbacks = waiting.toList()
                waiting.clear()
                if (!disposed) callbacks.forEach { it(connected) }
            }
        })
    }

    private fun query(product: String, callback: (ProductDetails?) -> Unit) {
        val item = QueryProductDetailsParams.Product.newBuilder().setProductId(product)
            .setProductType(BillingClient.ProductType.SUBS).build()
        client.queryProductDetailsAsync(QueryProductDetailsParams.newBuilder().setProductList(listOf(item)).build()) { result, details ->
            activity.runOnUiThread {
                if (!disposed) callback(details.productDetailsList.singleOrNull().takeIf { result.responseCode == 0 })
            }
        }
    }

    private fun plans(product: ProductDetails) = product.subscriptionOfferDetails.orEmpty().filter {
        val phase = it.pricingPhases.pricingPhaseList.singleOrNull()
        it.offerId == null && phase?.billingPeriod == "P1Y" &&
            phase.recurrenceMode == ProductDetails.RecurrenceMode.INFINITE_RECURRING
    }

    private fun purchase(value: Purchase) = mapOf("token" to value.purchaseToken, "products" to value.products)

    private fun handle(call: MethodCall, response: MethodChannel.Result) {
        if (call.method !in setOf("plans", "buy", "purchases")) {
            response.notImplemented()
            return
        }
        val product = call.argument<String>("product")
        if (product.isNullOrBlank()) {
            response.error("invalid_product", null, null)
            return
        }
        ready { connected ->
            if (!connected) {
                response.error("billing_unavailable", null, null)
                return@ready
            }
            if (call.method == "purchases") {
                val params = QueryPurchasesParams.newBuilder().setProductType(BillingClient.ProductType.SUBS).build()
                client.queryPurchasesAsync(params) { result, purchases -> activity.runOnUiThread {
                    if (!disposed) {
                        if (result.responseCode == 0) response.success(purchases.filter { product in it.products }.map(::purchase))
                        else response.error("billing_unavailable", null, null)
                    }
                } }
                return@ready
            }
            query(product) { details ->
                if (details == null) {
                    response.error("product_unavailable", null, null)
                    return@query
                }
                if (call.method == "plans") {
                    response.success(plans(details).map { mapOf(
                        "id" to it.basePlanId,
                        "price" to it.pricingPhases.pricingPhaseList.single().formattedPrice,
                    ) })
                    return@query
                }
                val offer = plans(details).singleOrNull { it.basePlanId == call.argument<String>("plan") }
                val account = call.argument<String>("account")
                val checkout = call.argument<String>("checkout")
                if (offer == null || account.isNullOrBlank() || checkout.isNullOrBlank()) {
                    response.error("invalid_plan", null, null)
                    return@query
                }
                val params = BillingFlowParams.ProductDetailsParams.newBuilder()
                    .setProductDetails(details).setOfferToken(offer.offerToken).build()
                response.success(client.launchBillingFlow(activity, BillingFlowParams.newBuilder()
                    .setProductDetailsParamsList(listOf(params))
                    .setObfuscatedAccountId(account).setObfuscatedProfileId(checkout).build()).responseCode)
            }
        }
    }

    fun dispose() {
        disposed = true
        waiting.clear()
        channel.setMethodCallHandler(null)
        client.endConnection()
    }
}
