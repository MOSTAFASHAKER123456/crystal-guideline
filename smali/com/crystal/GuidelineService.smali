# ═══════════════════════════════════════════════════════════════
# com/crystal/GuidelineService.smali
# Foreground Service that manages the GuidelineView overlay.
# Delayed creation (5 s) gives the game time to load its table.
# ═══════════════════════════════════════════════════════════════

.class public Lcom/crystal/GuidelineService;
.super Landroid/app/Service;

.field private handler:Landroid/os/Handler;
.field private view:Lcom/crystal/GuidelineView;
.field private wm:Landroid/view/WindowManager;

# ── onCreate ─────────────────────────────────────────────────
.method public onCreate()V
    .locals 4

    invoke-super {p0}, Landroid/app/Service;->onCreate()V

    # Build Handler on main Looper
    new-instance v0, Landroid/os/Handler;
    invoke-static {}, Landroid/os/Looper;->getMainLooper()Landroid/os/Looper;
    move-result-object v1
    invoke-direct {v0, v1}, Landroid/os/Handler;-><init>(Landroid/os/Looper;)V
    iput-object v0, p0, Lcom/crystal/GuidelineService;->handler:Landroid/os/Handler;

    # Grab WindowManager early (valid from Service context)
    const-string v1, "window"
    invoke-virtual {p0, v1}, Landroid/content/Context;->getSystemService(Ljava/lang/String;)Ljava/lang/Object;
    move-result-object v1
    iput-object v1, p0, Lcom/crystal/GuidelineService;->wm:Landroid/view/WindowManager;

    return-void
.end method

# ── onStartCommand: post delayed overlay creation ────────────
.method public onStartCommand(Landroid/content/Intent;II)I
    .locals 4

    iget-object v0, p0, Lcom/crystal/GuidelineService;->handler:Landroid/os/Handler;

    # ShowGuidelineRunnable(service)
    new-instance v1, Lcom/crystal/ShowGuidelineRunnable;
    invoke-direct {v1, p0}, Lcom/crystal/ShowGuidelineRunnable;-><init>(Lcom/crystal/GuidelineService;)V

    const-wide v2, 5000L   # 5 second delay

    invoke-virtual {v0, v1, v2, v3}, Landroid/os/Handler;->postDelayed(Ljava/lang/Runnable;J)Z

    const/4 v0, 0x1        # START_STICKY
    return v0
.end method

# ── createOverlay: called by ShowGuidelineRunnable (main thread) ──
.method public createOverlay()V
    .locals 8

    # GuidelineView view = new GuidelineView(this)
    new-instance v0, Lcom/crystal/GuidelineView;
    invoke-direct {v0, p0}, Lcom/crystal/GuidelineView;-><init>(Landroid/content/Context;)V
    iput-object v0, p0, Lcom/crystal/GuidelineService;->view:Lcom/crystal/GuidelineView;

    # View must be hardware-accelerated for smooth redraws
    const/high16 v1, 0x100  # View.LAYER_TYPE_HARDWARE = 2
    const/4 v2, 0x0
    invoke-virtual {v0, v1, v2}, Landroid/view/View;->setLayerType(ILandroid/graphics/Paint;)V

    # WindowManager.LayoutParams
    new-instance v1, Landroid/view/WindowManager$LayoutParams;

    const/16 v2, 0x7F6     # TYPE_APPLICATION_OVERLAY = 2038 = 0x7F6
    const/4  v3, -1        # MATCH_PARENT width
    const/4  v4, -1        # MATCH_PARENT height
    # FLAG_NOT_FOCUSABLE | FLAG_NOT_TOUCH_MODAL | FLAG_LAYOUT_IN_SCREEN
    const/16 v5, 0x228
    const/16 v6, -3        # PixelFormat.TRANSLUCENT

    invoke-direct {v1, v2, v3, v4, v5, v6}, Landroid/view/WindowManager$LayoutParams;-><init>(IIIII)V

    # addView
    iget-object v2, p0, Lcom/crystal/GuidelineService;->wm:Landroid/view/WindowManager;
    invoke-interface {v2, v0, v1}, Landroid/view/WindowManager;->addView(Landroid/view/View;Landroid/view/ViewGroup$LayoutParams;)V

    return-void
.end method

# ── onBind (required stub) ───────────────────────────────────
.method public onBind(Landroid/content/Intent;)Landroid/os/IBinder;
    .locals 1
    const/4 v0, 0x0
    return-object v0
.end method

# ── onDestroy ────────────────────────────────────────────────
.method public onDestroy()V
    .locals 2

    iget-object v0, p0, Lcom/crystal/GuidelineService;->wm:Landroid/view/WindowManager;
    iget-object v1, p0, Lcom/crystal/GuidelineService;->view:Lcom/crystal/GuidelineView;

    if-eqz v0, :skip
    if-eqz v1, :skip
    invoke-interface {v0, v1}, Landroid/view/WindowManager;->removeView(Landroid/view/View;)V

    :skip
    iget-object v0, p0, Lcom/crystal/GuidelineService;->handler:Landroid/os/Handler;
    if-eqz v0, :done
    invoke-virtual {v0}, Landroid/os/Handler;->removeCallbacksAndMessages(Ljava/lang/Object;)V

    :done
    invoke-super {p0}, Landroid/app/Service;->onDestroy()V
    return-void
.end method
