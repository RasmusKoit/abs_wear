package dev.koit.abs_wear

import android.os.Bundle
import android.view.MotionEvent
import com.ryanheise.audioservice.AudioServiceActivity
import com.samsung.wearable_rotary.WearableRotaryPlugin

/**
 * Extends [AudioServiceActivity] (required by just_audio_background) so that
 * this activity can be the launcher activity and still forward rotary input.
 */
class MainActivity : AudioServiceActivity() {

    /**
     * Hooks rotary input (crown / bezel) into the "WearableRotaryPlugin" class.
     */
    override fun onGenericMotionEvent(event: MotionEvent?): Boolean {
        return when {
            WearableRotaryPlugin.onGenericMotionEvent(event) -> true
            else -> super.onGenericMotionEvent(event)
        }
    }

    /**
     * Makes the app assume the rounded canvas appearance on rounded screens.
     */
    override fun onCreate(savedInstanceState: Bundle?) {
        intent.putExtra("background_mode", "transparent")
        super.onCreate(savedInstanceState)
    }
}
