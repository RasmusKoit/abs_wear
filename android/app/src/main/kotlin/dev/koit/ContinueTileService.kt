package dev.koit.abs_wear

import androidx.concurrent.futures.CallbackToFutureAdapter
import androidx.wear.protolayout.ActionBuilders
import androidx.wear.protolayout.ColorBuilders.argb
import androidx.wear.protolayout.DimensionBuilders.dp
import androidx.wear.protolayout.DimensionBuilders.expand
import androidx.wear.protolayout.DimensionBuilders.sp
import androidx.wear.protolayout.LayoutElementBuilders
import androidx.wear.protolayout.ModifiersBuilders
import androidx.wear.protolayout.ResourceBuilders
import androidx.wear.protolayout.TimelineBuilders
import androidx.wear.tiles.RequestBuilders
import androidx.wear.tiles.TileBuilders
import androidx.wear.tiles.TileService
import com.google.common.util.concurrent.ListenableFuture
import kotlin.concurrent.thread

/** "Continue listening" tile: the latest book from the cached shelf; a tap opens its player. */
class ContinueTileService : TileService() {

    override fun onTileRequest(
        requestParams: RequestBuilders.TileRequest,
    ): ListenableFuture<TileBuilders.Tile> = CallbackToFutureAdapter.getFuture { completer ->
        // Off the main thread: reads a file.
        thread {
            try {
                completer.set(tile(ContinueTile.cachedBook(this)))
            } catch (e: Exception) {
                completer.setException(e)
            }
        }
        "ContinueTileService.onTileRequest"
    }

    override fun onTileResourcesRequest(
        requestParams: RequestBuilders.ResourcesRequest,
    ): ListenableFuture<ResourceBuilders.Resources> = CallbackToFutureAdapter.getFuture { completer ->
        completer.set(ResourceBuilders.Resources.Builder().setVersion(RESOURCES_VERSION).build())
        "ContinueTileService.onTileResourcesRequest"
    }

    private fun tile(book: ContinueTile.Book?): TileBuilders.Tile {
        val column = LayoutElementBuilders.Column.Builder()
            .setHorizontalAlignment(LayoutElementBuilders.HORIZONTAL_ALIGN_CENTER)
        if (book == null) {
            column.addContent(text(applicationInfo.loadLabel(packageManager).toString(), 16f, WHITE, 2))
        } else {
            column.addContent(text(getString(R.string.continue_listening), 12f, GREY, 1))
                .addContent(spacer(6f))
                .addContent(text(book.title, 16f, WHITE, 3))
            if (book.author.isNotEmpty()) {
                column.addContent(spacer(4f)).addContent(text(book.author, 12f, GREY, 1))
            }
        }
        val root = LayoutElementBuilders.Box.Builder()
            .setWidth(expand())
            .setHeight(expand())
            .setHorizontalAlignment(LayoutElementBuilders.HORIZONTAL_ALIGN_CENTER)
            .setVerticalAlignment(LayoutElementBuilders.VERTICAL_ALIGN_CENTER)
            .setModifiers(
                ModifiersBuilders.Modifiers.Builder()
                    .setClickable(
                        ModifiersBuilders.Clickable.Builder()
                            .setId("open")
                            .setOnClick(open(book))
                            .build(),
                    )
                    // Keeps text inside a round screen.
                    .setPadding(
                        ModifiersBuilders.Padding.Builder()
                            .setStart(dp(28f)).setEnd(dp(28f))
                            .setTop(dp(24f)).setBottom(dp(24f))
                            .build(),
                    )
                    .build(),
            )
            .addContent(column.build())
            .build()
        return TileBuilders.Tile.Builder()
            .setResourcesVersion(RESOURCES_VERSION)
            .setTileTimeline(TimelineBuilders.Timeline.fromLayoutElement(root))
            .build()
    }

    private fun open(book: ContinueTile.Book?): ActionBuilders.LaunchAction {
        val activity = ActionBuilders.AndroidActivity.Builder()
            .setPackageName(packageName)
            .setClassName(MainActivity::class.java.name)
        if (book != null) {
            activity.addKeyToExtraMapping(ContinueTile.EXTRA_ITEM, stringExtra(book.id))
            book.episodeId?.let { activity.addKeyToExtraMapping(ContinueTile.EXTRA_EPISODE, stringExtra(it)) }
        }
        return ActionBuilders.LaunchAction.Builder().setAndroidActivity(activity.build()).build()
    }

    private fun stringExtra(value: String) = ActionBuilders.AndroidStringExtra.Builder().setValue(value).build()

    private fun spacer(height: Float) = LayoutElementBuilders.Spacer.Builder().setHeight(dp(height)).build()

    private fun text(value: String, size: Float, color: Int, maxLines: Int) =
        LayoutElementBuilders.Text.Builder()
            .setText(value)
            .setMaxLines(maxLines)
            .setMultilineAlignment(LayoutElementBuilders.TEXT_ALIGN_CENTER)
            .setOverflow(LayoutElementBuilders.TEXT_OVERFLOW_ELLIPSIZE_END)
            .setFontStyle(
                LayoutElementBuilders.FontStyle.Builder()
                    .setSize(sp(size))
                    .setColor(argb(color))
                    .build(),
            )
            .build()

    private companion object {
        const val RESOURCES_VERSION = "1"
        const val WHITE = 0xFFFFFFFF.toInt()
        const val GREY = 0xFFB0B0B0.toInt()
    }
}
