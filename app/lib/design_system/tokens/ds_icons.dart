import 'package:flutter/widgets.dart';
import 'package:remixicon/remixicon.dart';

/// Design System v3.0 统一现代矢量图标语义字典（基于 `remixicon`）。
///
/// 通过 `design_system.dart` 单一出口暴露给全部业务域，确保全仓维持
/// 统一的 1.5px 几何线宽、圆角风格与选态 `_line` / `_fill` 配对，
/// 彻底淘汰混用的原生默认图标。
abstract final class DsIcons {
  // ---------------------------------------------------------------------------
  // 底部导航与中置语音指令键
  // ---------------------------------------------------------------------------
  static const IconData navCommandLine = RemixIcons.dashboard_line;
  static const IconData navCommandFill = RemixIcons.dashboard_fill;
  static const IconData navMonitorLine = RemixIcons.radar_line;
  static const IconData navMonitorFill = RemixIcons.radar_fill;
  static const IconData navCopilotLine = RemixIcons.sparkling_2_line;
  static const IconData navCopilotFill = RemixIcons.sparkling_2_fill;
  static const IconData navProfileLine = RemixIcons.user_3_line;
  static const IconData navProfileFill = RemixIcons.user_3_fill;
  static const IconData voiceLine = RemixIcons.mic_line;
  static const IconData voiceFill = RemixIcons.mic_fill;

  // ---------------------------------------------------------------------------
  // 警情三大分类（火灾 / 抢险 / 救助 — 头部胶囊与列表徽章严格统一）
  // ---------------------------------------------------------------------------
  static const IconData categoryFire = RemixIcons.fire_fill;
  static const IconData categoryFireLine = RemixIcons.fire_line;
  static const IconData categoryRescue = RemixIcons.shield_flash_fill;
  static const IconData categoryRescueLine = RemixIcons.shield_flash_line;
  static const IconData categoryAid = RemixIcons.hand_heart_fill;
  static const IconData categoryAidLine = RemixIcons.hand_heart_line;

  // ---------------------------------------------------------------------------
  // 指挥台 9 项现场工具（统一 1.5px 现代几何线条）
  // ---------------------------------------------------------------------------
  static const IconData toolKeySites = RemixIcons.building_2_line;
  static const IconData toolHazmat = RemixIcons.flask_line;
  static const IconData toolWatermarkCamera = RemixIcons.camera_3_line;
  static const IconData toolLocationShare = RemixIcons.focus_3_line;
  static const IconData toolVideoResources = RemixIcons.vidicon_line;
  static const IconData toolRouteTraffic = RemixIcons.route_line;
  static const IconData toolTacticalBrief = RemixIcons.file_text_line;
  static const IconData toolSceneMap = RemixIcons.map_2_line;
  static const IconData toolWaterSources = RemixIcons.drop_line;

  // ---------------------------------------------------------------------------
  // 状态、连接与风险语义
  // ---------------------------------------------------------------------------
  static const IconData connOnline = RemixIcons.cloud_line;
  static const IconData connReconnecting = RemixIcons.refresh_line;
  static const IconData connOffline = RemixIcons.cloud_off_line;

  static const IconData statusSafe = RemixIcons.checkbox_circle_fill;
  static const IconData statusCaution = RemixIcons.error_warning_fill;
  static const IconData statusAlarm = RemixIcons.alarm_warning_fill;
  static const IconData statusTimeout = RemixIcons.timer_flash_fill;
  static const IconData statusNeutral = RemixIcons.information_line;

  static const IconData warning = RemixIcons.error_warning_line;
  static const IconData time = RemixIcons.time_line;
  static const IconData truck = RemixIcons.truck_line;
  static const IconData shield = RemixIcons.shield_line;
  static const IconData shieldCheck = RemixIcons.shield_check_line;

  // ---------------------------------------------------------------------------
  // 「我的」与系统设置菜单（统一沉稳细线风格）
  // ---------------------------------------------------------------------------
  static const IconData watermark = RemixIcons.image_edit_line;
  static const IconData video = RemixIcons.vidicon_line;
  static const IconData memberApprove = RemixIcons.user_follow_line;
  static const IconData roster = RemixIcons.group_line;
  static const IconData stations = RemixIcons.team_line;
  static const IconData archive = RemixIcons.archive_drawer_line;
  static const IconData stats = RemixIcons.bar_chart_box_line;
  static const IconData opLog = RemixIcons.history_line;
  static const IconData calculator = RemixIcons.calculator_line;
  static const IconData alerts = RemixIcons.notification_3_line;
  static const IconData alertsOff = RemixIcons.notification_off_line;
  static const IconData appearance = RemixIcons.palette_line;
  static const IconData server = RemixIcons.server_line;
  static const IconData update = RemixIcons.download_cloud_2_line;
  static const IconData info = RemixIcons.information_line;
  static const IconData qrScan = RemixIcons.qr_scan_2_line;
  static const IconData gallery = RemixIcons.layout_grid_2_line;
  static const IconData sun = RemixIcons.sun_line;
  static const IconData moon = RemixIcons.moon_line;
  static const IconData volumeUp = RemixIcons.volume_up_line;
  static const IconData volumeMute = RemixIcons.volume_mute_line;
  static const IconData forbid = RemixIcons.forbid_2_line;
  static const IconData download = RemixIcons.download_2_line;
  static const IconData checkCircle = RemixIcons.checkbox_circle_line;
  static const IconData checkCircleFill = RemixIcons.checkbox_circle_fill;
  static const IconData sync = RemixIcons.refresh_line;

  // ---------------------------------------------------------------------------
  // 通用交互、日志、认证、智能辅助与空呼监控
  // ---------------------------------------------------------------------------
  static const IconData search = RemixIcons.search_2_line;
  static const IconData refresh = RemixIcons.refresh_line;
  static const IconData close = RemixIcons.close_line;
  static const IconData closeCircle = RemixIcons.close_circle_line;
  static const IconData add = RemixIcons.add_line;
  static const IconData addCircle = RemixIcons.add_circle_line;
  static const IconData chevronRight = RemixIcons.arrow_right_s_line;
  static const IconData chevronDown = RemixIcons.arrow_down_s_line;
  static const IconData chevronUp = RemixIcons.arrow_up_s_line;
  static const IconData arrowRight = RemixIcons.arrow_right_line;
  static const IconData arrowUpRight = RemixIcons.arrow_right_up_line;
  static const IconData more = RemixIcons.more_2_fill;
  static const IconData moreHoriz = RemixIcons.more_fill;
  static const IconData edit = RemixIcons.edit_box_line;
  static const IconData note = RemixIcons.file_edit_line;
  static const IconData delete = RemixIcons.delete_bin_6_line;
  static const IconData clearSweep = RemixIcons.delete_bin_line;
  static const IconData copy = RemixIcons.file_copy_line;
  static const IconData send = RemixIcons.send_plane_2_fill;
  static const IconData keyboard = RemixIcons.keyboard_box_line;
  static const IconData camera = RemixIcons.camera_3_line;
  static const IconData photoLibrary = RemixIcons.image_line;
  static const IconData eye = RemixIcons.eye_line;
  static const IconData eyeOff = RemixIcons.eye_off_line;
  static const IconData password = RemixIcons.lock_password_line;
  static const IconData user = RemixIcons.user_3_line;
  static const IconData userAdd = RemixIcons.user_add_line;
  static const IconData unit = RemixIcons.building_2_line;
  static const IconData compass = RemixIcons.compass_discover_line;
  static const IconData verified = RemixIcons.verified_badge_line;
  static const IconData idCard = RemixIcons.id_card_line;
  static const IconData lock = RemixIcons.lock_line;
  static const IconData inbox = RemixIcons.inbox_2_line;
  static const IconData soundWave = RemixIcons.equalizer_line;
  static const IconData phone = RemixIcons.phone_line;
  static const IconData logout = RemixIcons.logout_box_r_line;
  static const IconData swap = RemixIcons.swap_line;
  static const IconData hourglass = RemixIcons.hourglass_line;
  static const IconData lightbulb = RemixIcons.lightbulb_line;
  static const IconData gasMeter = RemixIcons.dashboard_3_line;
  static const IconData doorLock = RemixIcons.door_lock_box_line;
  static const IconData broadcast = RemixIcons.megaphone_line;
  static const IconData device = RemixIcons.smartphone_line;
  static const IconData computer = RemixIcons.computer_line;
  static const IconData check = RemixIcons.check_line;
  static const IconData flag = RemixIcons.flag_line;
  static const IconData timeline = RemixIcons.route_line;

  // ---------------------------------------------------------------------------
  // 视频、相机与媒体预览
  // ---------------------------------------------------------------------------
  static const IconData videoOff = RemixIcons.video_off_line;
  static const IconData videoLibrary = RemixIcons.movie_2_line;
  static const IconData play = RemixIcons.play_fill;
  static const IconData playCircle = RemixIcons.play_circle_line;
  static const IconData pauseCircle = RemixIcons.pause_circle_line;
  static const IconData stop = RemixIcons.stop_fill;
  static const IconData stopCircle = RemixIcons.stop_circle_line;
  static const IconData fullscreen = RemixIcons.fullscreen_line;
  static const IconData fullscreenExit = RemixIcons.fullscreen_exit_line;
  static const IconData pip = RemixIcons.picture_in_picture_2_line;
  static const IconData flashOn = RemixIcons.flashlight_fill;
  static const IconData flashOff = RemixIcons.flashlight_line;
  static const IconData cameraSwitch = RemixIcons.camera_switch_line;
  static const IconData cameraOff = RemixIcons.camera_off_line;
  static const IconData recordDot = RemixIcons.record_circle_fill;
  static const IconData micOff = RemixIcons.mic_off_line;
  static const IconData cleanSweep = RemixIcons.brush_2_line;
  static const IconData filter = RemixIcons.filter_3_line;
  static const IconData zoomMap = RemixIcons.zoom_in_line;
  static const IconData externalLink = RemixIcons.external_link_line;
  static const IconData share = RemixIcons.share_forward_line;
  static const IconData imageBroken = RemixIcons.image_2_line;
  static const IconData folderOpen = RemixIcons.folder_open_line;
  static const IconData rotateRight = RemixIcons.clockwise_2_line;
  static const IconData fitScreen = RemixIcons.aspect_ratio_line;
  static const IconData dragHandle = RemixIcons.menu_line;

  // ---------------------------------------------------------------------------
  // 地图、坐标与水源设施
  // ---------------------------------------------------------------------------
  static const IconData locationPin = RemixIcons.map_pin_2_line;
  static const IconData locationAdd = RemixIcons.map_pin_add_line;
  static const IconData locationOff = RemixIcons.global_off_line;
  static const IconData myLocation = RemixIcons.crosshair_2_line;
  static const IconData navigation = RemixIcons.navigation_line;
  static const IconData satellite = RemixIcons.earth_line;
  static const IconData traffic = RemixIcons.traffic_light_line;
  static const IconData altRoute = RemixIcons.guide_line;
  static const IconData hydrant = RemixIcons.water_percent_line;
  static const IconData plumbing = RemixIcons.tools_line;

  // ---------------------------------------------------------------------------
  // 危化、监测、队站、归档与语音明细
  // ---------------------------------------------------------------------------
  static const IconData login = RemixIcons.login_box_line;
  static const IconData merge = RemixIcons.git_merge_line;
  static const IconData repeat = RemixIcons.repeat_2_line;
  static const IconData calendar = RemixIcons.calendar_2_line;
  static const IconData clipboard = RemixIcons.clipboard_line;
  static const IconData taskCheck = RemixIcons.task_line;
  static const IconData tag = RemixIcons.price_tag_3_line;
  static const IconData linkOff = RemixIcons.link_unlink;
  static const IconData copyAll = RemixIcons.file_copy_2_line;
  static const IconData book = RemixIcons.book_open_line;
  static const IconData wind = RemixIcons.windy_line;
  static const IconData firstAid = RemixIcons.first_aid_kit_line;
  static const IconData prohibited = RemixIcons.prohibited_line;
  static const IconData distance = RemixIcons.expand_diagonal_line;
  static const IconData toggleOn = RemixIcons.toggle_fill;
  static const IconData toggleOff = RemixIcons.toggle_line;
  static const IconData radioUnchecked = RemixIcons.checkbox_blank_circle_line;
  static const IconData cancelFill = RemixIcons.close_circle_fill;
  static const IconData chevronLeft = RemixIcons.arrow_left_s_line;
  static const IconData tune = RemixIcons.equalizer_2_line;
  static const IconData settings = RemixIcons.settings_3_line;
  static const IconData cloudUpload = RemixIcons.upload_cloud_2_line;
  static const IconData list = RemixIcons.list_unordered;
  static const IconData searchOff = RemixIcons.search_eye_line;
  static const IconData sparkle = RemixIcons.sparkling_2_line;
  static const IconData orgTree = RemixIcons.organization_chart;
  static const IconData receipt = RemixIcons.file_list_3_line;
  static const IconData scanner = RemixIcons.scan_2_line;
  static const IconData touch = RemixIcons.hand;
  static const IconData speak = RemixIcons.speak_line;
  static const IconData community = RemixIcons.community_line;
  static const IconData fireExtinguisher = RemixIcons.fire_line;
  static const IconData offlinePin = RemixIcons.checkbox_circle_line;
}
