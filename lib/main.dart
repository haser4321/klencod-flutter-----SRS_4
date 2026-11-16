
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

late SRSPlaybackHandler audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  audioHandler = await AudioService.init<SRSPlaybackHandler>(
    builder: () => SRSPlaybackHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.playermusicsrs.srs.audio',
      androidNotificationChannelName: 'SRS Music Player',
      androidNotificationChannelDescription: 'SRS audio playback controls',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      androidNotificationIcon: 'drawable/ic_launcher',
    ),
  );

  runApp(const SRSApp());
}

// ------------------------------------------------------------
// AUDIO HANDLER
// ------------------------------------------------------------

class SRSPlaybackHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  final AndroidEqualizer equalizer = AndroidEqualizer();

  late final AudioPlayer player;

  SRSPlaybackHandler() {
    player = AudioPlayer(
      audioPipeline: AudioPipeline(
        androidAudioEffects: [equalizer],
      ),
    );

    player.playbackEventStream.listen((event) {
      _broadcastState();
    });

    player.currentIndexStream.listen((index) {
      if (index != null &&
          index >= 0 &&
          index < queue.value.length) {
        mediaItem.add(queue.value[index]);
      }

      _broadcastState();
    });

    player.playerStateStream.listen((state) {
      _broadcastState();
    });
  }

  bool get repeatOne => player.loopMode == LoopMode.one;

  Future<void> setPlaylist(
    List<MediaItem> items, {
    required int initialIndex,
  }) async {
    if (items.isEmpty) return;

    queue.add(items);

    final sources = items.map((item) {
      return AudioSource.uri(
        Uri.file(item.id),
        tag: item,
      );
    }).toList();

    await player.setAudioSources(
      sources,
      initialIndex: initialIndex,
      initialPosition: Duration.zero,
    );

    if (initialIndex >= 0 && initialIndex < items.length) {
      mediaItem.add(items[initialIndex]);
    }

    _broadcastState();
  }

  Future<void> toggleRepeatOne() async {
    final enabled = !repeatOne;

    await player.setLoopMode(
      enabled ? LoopMode.one : LoopMode.off,
    );

    _broadcastState();
  }

  @override
  Future<dynamic> customAction(
    String name, [
    Map<String, dynamic>? extras,
  ]) async {
    if (name == 'toggleRepeatOne') {
      await toggleRepeatOne();
    }
  }

  @override
  Future<void> play() async {
    await player.play();
  }

  @override
  Future<void> pause() async {
    await player.pause();
  }

  @override
  Future<void> stop() async {
    await player.stop();
    await super.stop();
    _broadcastState();
  }

  @override
  Future<void> seek(Duration position) async {
    await player.seek(position);
  }

  @override
  Future<void> skipToNext() async {
    if (player.hasNext) {
      await player.seekToNext();
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (player.hasPrevious) {
      await player.seekToPrevious();
    }
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index >= 0 && index < queue.value.length) {
      await player.seek(Duration.zero, index: index);
    }
  }

  void _broadcastState() {
    final state = player.processingState;

    final processingState = switch (state) {
      ProcessingState.idle => AudioProcessingState.idle,
      ProcessingState.loading => AudioProcessingState.loading,
      ProcessingState.buffering => AudioProcessingState.buffering,
      ProcessingState.ready => AudioProcessingState.ready,
      ProcessingState.completed => AudioProcessingState.completed,
    };

    final controls = <MediaControl>[
      MediaControl.skipToPrevious,
      MediaControl.custom(
        androidIcon: 'drawable/ic_repeat_one',
        label: repeatOne ? 'Repeat One: On' : 'Repeat One: Off',
        name: 'toggleRepeatOne',
      ),
      if (player.playing)
        MediaControl.pause
      else
        MediaControl.play,
      MediaControl.skipToNext,
    ];

    playbackState.add(
      PlaybackState(
        controls: controls,
        androidCompactActionIndices: const [0, 1, 2],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        processingState: processingState,
        playing: player.playing,
        updatePosition: player.position,
        bufferedPosition: player.bufferedPosition,
        speed: player.speed,
        queueIndex: player.currentIndex,
        repeatMode: repeatOne
            ? AudioServiceRepeatMode.one
            : AudioServiceRepeatMode.none,
      ),
    );
  }
}

// ------------------------------------------------------------
// TRACK MODEL
// ------------------------------------------------------------

class Track {
  final String path;
  final String name;

  Track({
    required this.path,
    required this.name,
  });

  String get title {
    return name.replaceAll(
      RegExp(r'\.mp3$', caseSensitive: false),
      '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'path': path,
      'name': name,
    };
  }

  factory Track.fromJson(Map<String, dynamic> json) {
    return Track(
      path: json['path'] as String,
      name: json['name'] as String,
    );
  }

  MediaItem toMediaItem() {
    return MediaItem(
      id: path,
      title: title,
      album: 'SRS MUSIC PLAYER',
      artist: 'SRS',
    );
  }
}

const List<Color> srsColors = [
  Color(0xFF9475D9),
  Color(0xFF4B9BC5),
  Color(0xFF38A68A),
  Color(0xFFD5A34C),
];

// ------------------------------------------------------------
// APP
// ------------------------------------------------------------

class SRSApp extends StatefulWidget {
  const SRSApp({super.key});

  @override
  State<SRSApp> createState() => _SRSAppState();
}

class _SRSAppState extends State<SRSApp> {
  int themeIndex = 0;

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();

    if (!mounted) return;

    setState(() {
      themeIndex = prefs.getInt('srs_theme') ?? 0;
    });
  }

  Future<void> changeTheme(int value) async {
    setState(() => themeIndex = value);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('srs_theme', value);
  }

  @override
  Widget build(BuildContext context) {
    final light = themeIndex == 3;
    final accent = srsColors[themeIndex];

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SRS Music Player',
      theme: ThemeData(
        useMaterial3: true,
        brightness: light ? Brightness.light : Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: accent,
          brightness: light ? Brightness.light : Brightness.dark,
        ),
        scaffoldBackgroundColor:
            light ? const Color(0xFFF6F5F8) : const Color(0xFF101116),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: false,
        ),
        sliderTheme: SliderThemeData(
          activeTrackColor: accent,
          thumbColor: accent,
          overlayColor: accent.withOpacity(0.15),
        ),
      ),
      home: SRSHome(
        themeIndex: themeIndex,
        onThemeChanged: changeTheme,
      ),
    );
  }
}

// ------------------------------------------------------------
// HOME
// ------------------------------------------------------------

class SRSHome extends StatefulWidget {
  final int themeIndex;
  final ValueChanged<int> onThemeChanged;

  const SRSHome({
    super.key,
    required this.themeIndex,
    required this.onThemeChanged,
  });

  @override
  State<SRSHome> createState() => _SRSHomeState();
}

class _SRSHomeState extends State<SRSHome> {
  final AudioPlayer _player = audioHandler.player;
  AndroidEqualizer get _equalizer => audioHandler.equalizer;

  List<Track> songs = [];
  List<String> favorites = [];

  int currentIndex = -1;
  int pageIndex = 0;

  bool showFavorites = false;
  String searchText = '';
  String lyrics = '';

  final TextEditingController searchController =
      TextEditingController();

  Future<AndroidEqualizerParameters>? eqFuture;

  StreamSubscription<int?>? indexSubscription;
  StreamSubscription<PlayerState>? stateSubscription;

  Color get accent => srsColors[widget.themeIndex];

  Track? get currentTrack {
    if (currentIndex < 0 || currentIndex >= songs.length) {
      return null;
    }

    return songs[currentIndex];
  }

  @override
  void initState() {
    super.initState();

    _loadSavedData();

    indexSubscription = _player.currentIndexStream.listen((index) {
      if (!mounted) return;

      setState(() {
        currentIndex = index ?? -1;
      });
    });

    stateSubscription = _player.playerStateStream.listen((state) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _loadSavedData() async {
    final prefs = await SharedPreferences.getInstance();

    final savedSongs = prefs.getString('srs_library');

    List<Track> loadedSongs = [];

    if (savedSongs != null) {
      try {
        final decoded = jsonDecode(savedSongs) as List;

        loadedSongs = decoded
            .map(
              (item) => Track.fromJson(
                Map<String, dynamic>.from(item),
              ),
            )
            .where((track) => File(track.path).existsSync())
            .toList();
      } catch (_) {
        loadedSongs = [];
      }
    }

    if (!mounted) return;

    setState(() {
      songs = loadedSongs;
      favorites = prefs.getStringList('srs_favorites') ?? [];
    });

    await _saveLibrary();
  }

  Future<void> _saveLibrary() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString(
      'srs_library',
      jsonEncode(songs.map((song) => song.toJson()).toList()),
    );
  }

  Future<void> _saveFavorites() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setStringList(
      'srs_favorites',
      favorites,
    );
  }

  @override
  void dispose() {
    indexSubscription?.cancel();
    stateSubscription?.cancel();
    searchController.dispose();
    super.dispose();
  }

  // ----------------------------------------------------------
  // IMPORT SINGLE MP3 FILES
  // ----------------------------------------------------------

  Future<void> _importSongs() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['mp3'],
        allowMultiple: true,
        withData: false,
      );

      if (result == null) return;

      int added = 0;

      for (final file in result.files) {
        final path = file.path;

        if (path == null ||
            !path.toLowerCase().endsWith('.mp3')) {
          continue;
        }

        final exists = songs.any(
          (song) => song.path.toLowerCase() == path.toLowerCase(),
        );

        if (!exists) {
          songs.add(
            Track(
              path: path,
              name: file.name,
            ),
          );

          added++;
        }
      }

      songs.sort(
        (a, b) => a.title.toLowerCase().compareTo(
              b.title.toLowerCase(),
            ),
      );

      await _saveLibrary();

      if (!mounted) return;

      setState(() {});

      _message(
        added > 0
            ? 'تمت إضافة $added أغنية'
            : 'لم تتم إضافة ملفات جديدة',
      );
    } catch (e) {
      _message('تعذر استيراد الملفات');
    }
  }

  // ----------------------------------------------------------
  // IMPORT WHOLE FOLDER
  // ----------------------------------------------------------

  Future<void> _importFolder() async {
    try {
      final folderPath = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'اختر مجلد الموسيقى',
      );

      if (folderPath == null) return;

      final directory = Directory(folderPath);

      if (!await directory.exists()) {
        _message('المجلد غير موجود أو لا يمكن الوصول إليه');
        return;
      }

      int added = 0;

      final existingPaths = songs
          .map((song) => song.path.toLowerCase())
          .toSet();

      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;

        final path = entity.path;

        if (!path.toLowerCase().endsWith('.mp3')) continue;

        if (existingPaths.contains(path.toLowerCase())) continue;

        final name = path.split(Platform.pathSeparator).last;

        songs.add(
          Track(
            path: path,
            name: name,
          ),
        );

        existingPaths.add(path.toLowerCase());
        added++;
      }

      songs.sort(
        (a, b) => a.title.toLowerCase().compareTo(
              b.title.toLowerCase(),
            ),
      );

      await _saveLibrary();

      if (!mounted) return;

      setState(() {});

      _message(
        added > 0
            ? 'تم العثور على $added ملف MP3 وإضافته'
            : 'لم يتم العثور على ملفات MP3 جديدة',
      );
    } catch (e) {
      _message(
        'تعذر قراءة المجلد. جرّب اختيار مجلد آخر.',
      );
    }
  }

  // ----------------------------------------------------------
  // PLAYBACK
  // ----------------------------------------------------------

  Future<void> _playTrack(int index) async {
    if (index < 0 || index >= songs.length) return;

    try {
      final items = songs.map((song) => song.toMediaItem()).toList();

      setState(() {
        currentIndex = index;
        lyrics = '';
        eqFuture = null;
      });

      await audioHandler.setPlaylist(
        items,
        initialIndex: index,
      );

      eqFuture = _equalizer.parameters;

      await audioHandler.play();

      if (mounted) setState(() {});
    } catch (e) {
      _message('تعذر تشغيل هذا الملف. تحقق من سلامة ملف MP3.');
    }
  }

  Future<void> _togglePlayback() async {
    if (currentTrack == null) {
      if (songs.isNotEmpty) {
        await _playTrack(0);
      } else {
        await _importSongs();
      }

      return;
    }

    if (_player.playing) {
      await audioHandler.pause();
    } else {
      await audioHandler.play();
    }

    if (mounted) setState(() {});
  }

  Future<void> _nextTrack() async {
    if (songs.isEmpty || currentIndex < 0) return;

    if (_player.hasNext) {
      await audioHandler.skipToNext();
    }
  }

  Future<void> _previousTrack() async {
    if (songs.isEmpty || currentIndex < 0) return;

    if (_player.position.inSeconds > 3) {
      await audioHandler.seek(Duration.zero);
    } else if (_player.hasPrevious) {
      await audioHandler.skipToPrevious();
    }
  }

  Future<void> _toggleRepeat() async {
    await audioHandler.toggleRepeatOne();

    if (mounted) setState(() {});
  }

  // ----------------------------------------------------------
  // FAVORITES
  // ----------------------------------------------------------

  Future<void> _toggleFavorite(Track track) async {
    setState(() {
      if (favorites.contains(track.path)) {
        favorites.remove(track.path);
      } else {
        favorites.add(track.path);
      }
    });

    await _saveFavorites();
  }

  // ----------------------------------------------------------
  // LYRICS
  // ----------------------------------------------------------

  Future<void> _pickLyrics() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt'],
        withData: true,
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      String content;

      if (file.bytes != null) {
        content = utf8.decode(
          file.bytes!,
          allowMalformed: true,
        );
      } else if (file.path != null) {
        content = await File(file.path!).readAsString();
      } else {
        _message('تعذر قراءة الملف');
        return;
      }

      setState(() => lyrics = content);
    } catch (e) {
      _message('تعذر فتح ملف الكلمات');
    }
  }

  void _message(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String _time(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60);

    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  List<Track> get displayedSongs {
    Iterable<Track> result = songs;

    if (showFavorites) {
      result = result.where(
        (song) => favorites.contains(song.path),
      );
    }

    if (searchText.isNotEmpty) {
      result = result.where(
        (song) => song.title.toLowerCase().contains(
              searchText.toLowerCase(),
            ),
      );
    }

    return result.toList();
  }

  // ----------------------------------------------------------
  // MAIN UI
  // ----------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 11,
                vertical: 5,
              ),
              decoration: BoxDecoration(
                border: Border.all(
                  color: accent.withOpacity(0.7),
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'SRS',
                style: TextStyle(
                  color: accent,
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 3,
                ),
              ),
            ),
            const SizedBox(width: 12),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'MUSIC PLAYER',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.4,
                  ),
                ),
                Text(
                  'YOUR MUSIC. YOUR WORLD.',
                  style: TextStyle(
                    fontSize: 8,
                    letterSpacing: 1.3,
                    color: Colors.grey,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _importFolder,
            icon: const Icon(Icons.create_new_folder_outlined),
            tooltip: 'إضافة مجلد موسيقى',
          ),
          IconButton(
            onPressed: _importSongs,
            icon: const Icon(Icons.add_rounded),
            tooltip: 'إضافة ملفات MP3',
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: IndexedStack(
                index: pageIndex,
                children: [
                  _libraryPage(),
                  _playerPage(),
                  _settingsPage(),
                ],
              ),
            ),
            if (currentTrack != null && pageIndex != 1)
              _miniPlayer(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: pageIndex,
        onDestinationSelected: (index) {
          setState(() => pageIndex = index);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.library_music_outlined),
            selectedIcon: Icon(Icons.library_music),
            label: 'المكتبة',
          ),
          NavigationDestination(
            icon: Icon(Icons.graphic_eq),
            selectedIcon: Icon(Icons.equalizer),
            label: 'المشغل',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune),
            selectedIcon: Icon(Icons.tune_rounded),
            label: 'الإعدادات',
          ),
        ],
      ),
    );
  }

  // ----------------------------------------------------------
  // LIBRARY
  // ----------------------------------------------------------

  Widget _libraryPage() {
    final list = displayedSongs;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'مكتبتك الموسيقية',
                style: TextStyle(
                  fontSize: 25,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                '${songs.length} ملف MP3',
                style: const TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: searchController,
                onChanged: (value) {
                  setState(() => searchText = value);
                },
                decoration: InputDecoration(
                  hintText: 'ابحث عن أغنية...',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest
                      .withOpacity(0.35),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(15),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  _filterButton('كل الأغاني', false),
                  const SizedBox(width: 8),
                  _filterButton('المفضلة', true),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: list.isEmpty
              ? _emptyLibrary()
              : ListView.builder(
                  padding: const EdgeInsets.only(
                    left: 15,
                    right: 15,
                    bottom: 20,
                  ),
                  itemCount: list.length,
                  itemBuilder: (context, index) {
                    final track = list[index];
                    final originalIndex = songs.indexOf(track);
                    final active = currentTrack?.path == track.path;

                    return Container(
                      margin: const EdgeInsets.only(bottom: 7),
                      decoration: BoxDecoration(
                        color: active
                            ? accent.withOpacity(0.12)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: ListTile(
                        onTap: () => _playTrack(originalIndex),
                        leading: Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            color: accent.withOpacity(0.14),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            active
                                ? Icons.equalizer
                                : Icons.music_note,
                            color: accent,
                          ),
                        ),
                        title: Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: active
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                        subtitle: const Text(
                          'MP3 AUDIO',
                          style: TextStyle(
                            fontSize: 10,
                            letterSpacing: 1.2,
                            color: Colors.grey,
                          ),
                        ),
                        trailing: IconButton(
                          onPressed: () => _toggleFavorite(track),
                          icon: Icon(
                            favorites.contains(track.path)
                                ? Icons.favorite
                                : Icons.favorite_border,
                            color: favorites.contains(track.path)
                                ? accent
                                : Colors.grey,
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _filterButton(String label, bool favorite) {
    final selected = showFavorites == favorite;

    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) {
        setState(() => showFavorites = favorite);
      },
      selectedColor: accent.withOpacity(0.25),
      side: BorderSide(
        color: selected ? accent : Colors.grey.withOpacity(0.2),
      ),
    );
  }

  Widget _emptyLibrary() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(25),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.library_music_outlined,
              size: 65,
              color: accent.withOpacity(0.6),
            ),
            const SizedBox(height: 15),
            const Text(
              'مكتبتك فارغة',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'أضف ملفات MP3 أو مجلداً كاملاً',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _importFolder,
              icon: const Icon(Icons.folder_open),
              label: const Text('اختيار مجلد الموسيقى'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _importSongs,
              icon: const Icon(Icons.add),
              label: const Text('اختيار ملفات MP3'),
            ),
          ],
        ),
      ),
    );
  }

  // ----------------------------------------------------------
  // PLAYER
  // ----------------------------------------------------------

  Widget _playerPage() {
    final track = currentTrack;

    if (track == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.headphones, size: 85, color: accent),
            const SizedBox(height: 20),
            const Text('لا توجد أغنية قيد التشغيل'),
            const SizedBox(height: 15),
            FilledButton(
              onPressed: _importSongs,
              child: const Text('اختيار الموسيقى'),
            ),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 25),
      child: Column(
        children: [
          const SizedBox(height: 15),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'NOW PLAYING',
                style: TextStyle(
                  color: Colors.grey,
                  letterSpacing: 2,
                  fontSize: 11,
                ),
              ),
              IconButton(
                onPressed: () => _toggleFavorite(track),
                icon: Icon(
                  favorites.contains(track.path)
                      ? Icons.favorite
                      : Icons.favorite_border,
                  color: accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 15),
          Container(
            width: 245,
            height: 245,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(32),
              gradient: LinearGradient(
                colors: [
                  accent.withOpacity(0.55),
                  accent.withOpacity(0.10),
                  Theme.of(context).colorScheme.surface,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              border: Border.all(
                color: accent.withOpacity(0.35),
              ),
              boxShadow: [
                BoxShadow(
                  color: accent.withOpacity(0.12),
                  blurRadius: 35,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Center(
              child: Text(
                'SRS',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.95),
                  fontSize: 65,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 7,
                  shadows: [
                    Shadow(
                      color: accent,
                      blurRadius: 20,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 25),
          Text(
            track.title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 5),
          const Text(
            'SRS AUDIO EXPERIENCE',
            style: TextStyle(
              color: Colors.grey,
              fontSize: 10,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 25),
          const SRSVisualizer(),
          const SizedBox(height: 15),
          _progressBar(),
          const SizedBox(height: 15),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _repeatButton(),
              const SizedBox(width: 8),
              IconButton(
                onPressed: _previousTrack,
                iconSize: 32,
                icon: const Icon(Icons.skip_previous_rounded),
              ),
              const SizedBox(width: 12),
              StreamBuilder<PlayerState>(
                stream: _player.playerStateStream,
                builder: (context, snapshot) {
                  final playing = snapshot.data?.playing ?? false;
                  final state = snapshot.data?.processingState;

                  final loading = state == ProcessingState.loading ||
                      state == ProcessingState.buffering;

                  return SizedBox(
                    width: 68,
                    height: 68,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        shape: const CircleBorder(),
                        backgroundColor: accent,
                        padding: EdgeInsets.zero,
                      ),
                      onPressed: loading ? null : _togglePlayback,
                      child: loading
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Icon(
                              playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              size: 39,
                            ),
                    ),
                  );
                },
              ),
              const SizedBox(width: 12),
              IconButton(
                onPressed: _nextTrack,
                iconSize: 32,
                icon: const Icon(Icons.skip_next_rounded),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _actionButton(
                Icons.lyrics_outlined,
                'الكلمات',
                _pickLyrics,
              ),
              _actionButton(
                Icons.equalizer,
                'المعادل',
                _showEqualizer,
              ),
            ],
          ),
          if (lyrics.isNotEmpty) ...[
            const SizedBox(height: 20),
            _lyricsCard(),
          ],
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _repeatButton() {
    return StreamBuilder<LoopMode>(
      stream: _player.loopModeStream,
      builder: (context, snapshot) {
        final enabled = (snapshot.data ?? LoopMode.off) == LoopMode.one;

        return IconButton(
          tooltip: enabled ? 'إيقاف تكرار الأغنية' : 'تكرار الأغنية',
          onPressed: _toggleRepeat,
          icon: Icon(
            Icons.repeat_one_rounded,
            size: 25,
            color: enabled ? accent : Colors.grey,
          ),
        );
      },
    );
  }

  Widget _progressBar() {
    return StreamBuilder<Duration>(
      stream: _player.positionStream,
      builder: (context, snapshot) {
        final position = snapshot.data ?? Duration.zero;
        final duration = _player.duration ?? Duration.zero;

        final max = duration.inMilliseconds > 0
            ? duration.inMilliseconds.toDouble()
            : 1.0;

        final value = position.inMilliseconds
            .toDouble()
            .clamp(0.0, max)
            .toDouble();

        return Column(
          children: [
            Slider(
              value: value,
              max: max,
              onChanged: duration.inMilliseconds <= 0
                  ? null
                  : (v) {
                      audioHandler.seek(
                        Duration(milliseconds: v.toInt()),
                      );
                    },
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _time(position),
                    style: const TextStyle(color: Colors.grey),
                  ),
                  Text(
                    _time(duration),
                    style: const TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _actionButton(
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    return InkWell(
      borderRadius: BorderRadius.circular(15),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: 24,
          vertical: 13,
        ),
        decoration: BoxDecoration(
          color: accent.withOpacity(0.10),
          borderRadius: BorderRadius.circular(15),
        ),
        child: Column(
          children: [
            Icon(icon, color: accent),
            const SizedBox(height: 5),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _lyricsCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: accent.withOpacity(0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: accent.withOpacity(0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lyrics, color: accent),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'LYRICS',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
              IconButton(
                onPressed: _pickLyrics,
                icon: const Icon(Icons.upload_file),
              ),
            ],
          ),
          const Divider(),
          SelectableText(
            lyrics,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 15,
              height: 2,
            ),
          ),
        ],
      ),
    );
  }

  // ----------------------------------------------------------
  // MINI PLAYER
  // ----------------------------------------------------------

  Widget _miniPlayer() {
    final track = currentTrack!;

    return InkWell(
      onTap: () => setState(() => pageIndex = 1),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 7,
        ),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(
            top: BorderSide(
              color: accent.withOpacity(0.2),
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.music_note, color: accent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            StreamBuilder<LoopMode>(
              stream: _player.loopModeStream,
              builder: (context, snapshot) {
                final enabled =
                    (snapshot.data ?? LoopMode.off) == LoopMode.one;

                return IconButton(
                  onPressed: _toggleRepeat,
                  icon: Icon(
                    Icons.repeat_one,
                    color: enabled ? accent : Colors.grey,
                    size: 21,
                  ),
                );
              },
            ),
            StreamBuilder<PlayerState>(
              stream: _player.playerStateStream,
              builder: (context, snapshot) {
                final playing = snapshot.data?.playing ?? false;

                return IconButton(
                  onPressed: _togglePlayback,
                  icon: Icon(
                    playing ? Icons.pause : Icons.play_arrow,
                    color: accent,
                  ),
                );
              },
            ),
            IconButton(
              onPressed: _nextTrack,
              icon: const Icon(Icons.skip_next),
            ),
          ],
        ),
      ),
    );
  }

  // ----------------------------------------------------------
  // SETTINGS
  // ----------------------------------------------------------

  Widget _settingsPage() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'الإعدادات',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 7),
        const Text(
          'خصص تجربة SRS الخاصة بك',
          style: TextStyle(color: Colors.grey),
        ),
        const SizedBox(height: 28),
        _sectionTitle('APPEARANCE'),
        const SizedBox(height: 12),
        const Text(
          'اختر الثيم',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 15),
        _themeOption(0, 'Royal Violet', 'بنفسجي ملكي'),
        _themeOption(1, 'Ocean Blue', 'أزرق المحيط'),
        _themeOption(2, 'Emerald', 'أخضر زمردي'),
        _themeOption(3, 'Pure Light', 'أبيض نقي'),
        const SizedBox(height: 25),
        _sectionTitle('AUDIO'),
        const SizedBox(height: 10),
        ListTile(
          leading: Icon(Icons.equalizer, color: accent),
          title: const Text('المعادل الصوتي'),
          subtitle: const Text('تعديل الترددات الصوتية'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _showEqualizer,
        ),
        const Divider(),
        ListTile(
          leading: Icon(Icons.repeat_one, color: accent),
          title: const Text('تكرار الأغنية الحالية'),
          subtitle: const Text('إعادة تشغيل الأغنية نفسها تلقائياً'),
          trailing: StreamBuilder<LoopMode>(
            stream: _player.loopModeStream,
            builder: (context, snapshot) {
              final enabled =
                  (snapshot.data ?? LoopMode.off) == LoopMode.one;

              return Switch(
                value: enabled,
                activeColor: accent,
                onChanged: (_) => _toggleRepeat(),
              );
            },
          ),
          onTap: _toggleRepeat,
        ),
        const Divider(),
        ListTile(
          leading: Icon(Icons.lyrics_outlined, color: accent),
          title: const Text('كلمات الأغاني'),
          subtitle: const Text('استيراد ملفات TXT'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _pickLyrics,
        ),
        const Divider(),
        ListTile(
          leading: Icon(Icons.folder_open, color: accent),
          title: const Text('إضافة مجلد موسيقى'),
          subtitle: const Text('استيراد جميع ملفات MP3 داخله'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _importFolder,
        ),
        const Divider(),
        ListTile(
          leading: Icon(Icons.library_music, color: accent),
          title: const Text('إضافة ملفات MP3'),
          subtitle: const Text('اختيار ملفات منفردة'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _importSongs,
        ),
        const SizedBox(height: 30),
        Center(
          child: Column(
            children: [
              Text(
                'SRS',
                style: TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 5,
                  color: accent,
                ),
              ),
              const Text(
                'MUSIC PLAYER',
                style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 3,
                  color: Colors.grey,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'VERSION 1.1.0',
                style: TextStyle(
                  color: Colors.grey,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: TextStyle(
        color: accent,
        fontSize: 11,
        fontWeight: FontWeight.bold,
        letterSpacing: 2,
      ),
    );
  }

  Widget _themeOption(
    int index,
    String name,
    String arabic,
  ) {
    final selected = widget.themeIndex == index;
    final color = srsColors[index];

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(13),
        border: Border.all(
          color: selected
              ? color
              : Colors.grey.withOpacity(0.2),
          width: selected ? 1.5 : 1,
        ),
      ),
      child: ListTile(
        onTap: () => widget.onThemeChanged(index),
        leading: CircleAvatar(
          backgroundColor: color,
          radius: 12,
        ),
        title: Text(name),
        subtitle: Text(arabic),
        trailing: selected
            ? Icon(Icons.check_circle, color: color)
            : const Icon(
                Icons.circle_outlined,
                color: Colors.grey,
              ),
      ),
    );
  }

  // ----------------------------------------------------------
  // EQUALIZER
  // ----------------------------------------------------------

  Future<void> _showEqualizer() async {
    if (currentTrack == null || eqFuture == null) {
      _message('شغّل أغنية أولاً لتفعيل المعادل الصوتي');
      return;
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _equalizerSheet(),
    );
  }

  Widget _equalizerSheet() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 25),
        child: FutureBuilder<AndroidEqualizerParameters>(
          future: eqFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const SizedBox(
                height: 250,
                child: Center(
                  child: CircularProgressIndicator(),
                ),
              );
            }

            if (!snapshot.hasData) {
              return const SizedBox(
                height: 200,
                child: Center(
                  child: Text('تعذر تهيئة المعادل الصوتي'),
                ),
              );
            }

            final parameters = snapshot.data!;

            return StatefulBuilder(
              builder: (context, localSetState) {
                return SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'SRS EQUALIZER',
                        style: TextStyle(
                          color: accent,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 2,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'تحكم مباشر في نطاقات الصوت على Android',
                        style: TextStyle(color: Colors.grey),
                      ),
                      const SizedBox(height: 20),
                      Wrap(
                        spacing: 7,
                        children: [
                          _presetChip(
                            'Normal',
                            parameters,
                            const [0, 0, 0, 0, 0],
                            localSetState,
                          ),
                          _presetChip(
                            'Bass',
                            parameters,
                            const [5, 4, 1, 0, -1],
                            localSetState,
                          ),
                          _presetChip(
                            'Voice',
                            parameters,
                            const [-2, 0, 3, 4, 2],
                            localSetState,
                          ),
                          _presetChip(
                            'Classical',
                            parameters,
                            const [3, 1, -1, 2, 3],
                            localSetState,
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('تفعيل المعادل'),
                        value: _equalizer.enabled,
                        activeColor: accent,
                        onChanged: (value) async {
                          await _equalizer.setEnabled(value);
                          localSetState(() {});
                        },
                      ),
                      const Divider(),
                      SizedBox(
                        height: 190,
                        child: Row(
                          mainAxisAlignment:
                              MainAxisAlignment.spaceEvenly,
                          children: parameters.bands.map((band) {
                            return Expanded(
                              child: Column(
                                children: [
                                  Expanded(
                                    child: RotatedBox(
                                      quarterTurns: 3,
                                      child: Slider(
                                        value: band.gain
                                            .clamp(
                                              parameters.minDecibels,
                                              parameters.maxDecibels,
                                            )
                                            .toDouble(),
                                        min: parameters.minDecibels,
                                        max: parameters.maxDecibels,
                                        onChanged: (value) async {
                                          await band.setGain(value);
                                          localSetState(() {});
                                        },
                                      ),
                                    ),
                                  ),
                                  Text(
                                    band.centerFrequency >= 1000
                                        ? '${(band.centerFrequency / 1000).toStringAsFixed(1)}k'
                                        : '${band.centerFrequency.toInt()}',
                                    style: const TextStyle(fontSize: 10),
                                  ),
                                  Text(
                                    band.gain.toStringAsFixed(1),
                                    style: const TextStyle(
                                      fontSize: 9,
                                      color: Colors.grey,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'الترددات بالهرتز • مستوى الصوت بالديسيبل',
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _presetChip(
    String name,
    AndroidEqualizerParameters parameters,
    List<double> values,
    StateSetter localSetState,
  ) {
    return ActionChip(
      label: Text(name),
      onPressed: () async {
        final bands = parameters.bands;

        for (int i = 0; i < bands.length; i++) {
          final profileIndex = bands.length == 1
              ? 0
              : (i * (values.length - 1) /
                      (bands.length - 1))
                  .round();

          final gain = values[profileIndex]
              .clamp(
                parameters.minDecibels,
                parameters.maxDecibels,
              )
              .toDouble();

          await bands[i].setGain(gain);
        }

        await _equalizer.setEnabled(true);
        localSetState(() {});
      },
    );
  }
}

// ------------------------------------------------------------
// VISUALIZER
// ------------------------------------------------------------

class SRSVisualizer extends StatefulWidget {
  const SRSVisualizer({super.key});

  @override
  State<SRSVisualizer> createState() => _SRSVisualizerState();
}

class _SRSVisualizerState extends State<SRSVisualizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;

  @override
  void initState() {
    super.initState();

    controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;

    return SizedBox(
      height: 55,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, child) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(31, (index) {
              final wave = sin(
                controller.value * pi * 2 + index * 0.45,
              ).abs();

              final center = 1 - ((index - 15).abs() / 17);
              final height = 8 + wave * 35 * center;

              return Container(
                width: 3.5,
                height: height,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  color: accent.withOpacity(0.45 + wave * 0.55),
                  borderRadius: BorderRadius.circular(5),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}